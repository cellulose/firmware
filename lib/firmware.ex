defmodule Firmware do

  @moduledoc """
  Handles firmware initialization and upgrades, dealing with flash storage, etc.
  see README for more information.
  """

  use GenServer

  require Logger
	require Hub

  # Partition defs -> boot partition, 2 rootfs partitions, and app storage area

  # CONFIGURATION OPTIONS FROM CONFIG.EXS

  @bootloader           Application.get_env :echo, :bootloader, :uboot

  @rootfs_partition Application.get_env :firmware, :rootfs_partitions, [
    a: "/dev/mmcblk0p2", 
    b: "/dev/mmcblk0p3"
  ]

  @boot_config_path     Application.get_env :firmware, :boot_config_path, 
                        "/boot/uEnv.txt"

  @fallback_config_path Application.get_env :echo, :boot_fallback_path, 
                        "/boot/uEnv_fallback.txt"
                        
  @flash_on_update      Application.get_env :firmware, :flash_on_update, nil
  
  # random storage areas in the application partition
  
  @app_area     "/root" # must exist in fstab
  @tmp_area     "#{@app_area}/tmp"
  @etc_area     "#{@app_area}/tmp"
  
  # firmware update specifications

  @fw_zip_filename    "fw_update.zip"
  @fw_zip_path        "#{@tmp_area}/#{@fw_zip_filename}"

  def app_area, do: @app_area
  def tmp_area, do: @tmp_area
  def etc_area, do: @etc_area
  def app_path(x), do: Path.join(app_area, x)
  def tmp_path(x), do: Path.join(tmp_area, x)
  def etc_path(x), do: Path.join(etc_area, x)

  ##################### GenServer Startup & Init Functions ###################

  def start(args \\ %{}) do
    GenServer.start __MODULE__, args
  end

  def start_link(args \\ %{}) do
    GenServer.start_link __MODULE__, args
  end

  def init(_args) do
    Logger.debug "mounting boot partition\n"
    result = :os.cmd('mount /boot')
    Logger.debug "returned #{result}"
    :timer.sleep(2)
    slot = read_boot_slot
    Logger.debug "read current slot as #{slot}"
    status = case :file.rename(@fallback_config_path, @boot_config_path) do
      :ok -> :provisional
      {:error, :enoent} -> :normal
    end
    Logger.debug "next boot slot will be '#{read_boot_slot}'"
    Logger.info "starting firmware in #{inspect status} mode"
    Logger.debug "mounting & tidying up the application storage area"
    mount_storage_area_and_tidy

    # REVIEW - requires Hub, perhaps should be broken out to another module
    # TODO major problem - this requires stuff inside the submodule
    
    Logger.info "firmware initialized, syncing disc..."
    sync_disk
    state = %{status: status, slot: slot}
    attach_to_hub(state)
    {:ok, state}
  end

  # a few assorted helpers to delegate to native erlang

  defp el2b(l), do: :erlang.list_to_binary(l)
  defp eb2l(b), do: :erlang.binary_to_list(b)
  defp eb2a(b), do: :erlang.binary_to_atom(b, :utf8)
  defp os_cmd(cmd) do
    :os.cmd(eb2l(cmd)) |> el2b
  end

  #REVIEW: HACK: This ensures that the renaming and copying of files gets written
  #to disk. Should be able to do with :os.cmd '/sbin/sync' as well but needs
  #to be tested BETTER YET this partition should be syncronous
  defp sync_disk do
    :os.cmd 'umount /boot'
    :os.cmd 'mount /boot'
  end

  defp slot_to_number(slot) do
    [a: 2, b: 3][:"#{slot}"]
  end

  # This macro handles the writing of the config file the bootloader reads
  # to determine which partition to boot from
  def write_config_file(slot) do
    slot_str = Atom.to_string(slot)
    case @bootloader do
      :syslinux ->
        File.write!(@boot_config_path,
                    "DEFAULT Linux-#{String.upcase(slot_str)}\n")
      :uboot ->
        case :file.read_file(@boot_config_path) do
          {:ok, data} ->
            Logger.debug "Writing uEnv: mmcblk0p#{slot_to_number(slot_str)}"
            output = String.replace(data,
                              ~r/mmcblk0p\d{1}/,
                              "mmcblk0p#{slot_to_number(slot_str)}")
            Logger.debug "Writing to uEnv.txt: #{output}"
            File.write! @boot_config_path, output
          _ ->
            Logger.debug "COULD NOT READ #{@boot_config_path} config file"
        end
      _ -> raise "Unknown bootloader, cannot continue"
    end
  end

  # Given contents of @boot_config_path (specified in application config) file,
  # return the slot it will boot  as :a|:b"
  defp cfg_to_slot(cfg) do
    case @bootloader do
      :syslinux ->
        Logger.debug "Searching for syslinux slot"
        <<"DEFAULT Linux-", cur_slot :: size(1)-binary, _rest :: binary>> = cfg
        #Possible BUG: if config file is corrupt then this will crash causing
        #endless reboots should probably set cur_slot to a as a backup??
        eb2a String.downcase(cur_slot)
      :uboot ->
        Logger.debug "Searching for uBoot slot"
        cond do
          String.contains?(cfg, "mmcblk0p2") -> :a
          String.contains?(cfg, "mmcblk0p3") -> :b
          true ->
            Logger.debug "No Slot found in config falling back to :a"
            :a
        end
      loader ->
        Logger.error "Bootloader #{inspect loader} not found, returning :a"
        :a
    end
  end

  defp write_initial_fallback do
    case @bootloader do
      :syslinux ->
        File.write!(@fallback_config_path, "DEFAULT Linux-A\n")
      _ ->
        nil
    end
  end


  # Prepares flash storage for use at normal startup time.
  # Mounts the application partition, and cleares out any tmp files left behind
  # Must be called (only once though) at startup to use firmware features
  defp mount_storage_area_and_tidy do
    :ok = mount(app_area)
    Logger.info "clearing out flash temporary storage area"
    File.rm_rf! tmp_area
    File.mkdir_p! tmp_area
    File.mkdir_p app_area
  end

  # Mounts a filesystem, logging and returning error if appropriate.
  defp mount(fstab_area) do
    Logger.info "mounting #{fstab_area}"
    :ok = exec "mount #{fstab_area}"
  end

  # Looks up what slot we would boot from if we rebooted right now
  # always returns :a or :b, hopefully, or something's really wrong and we crash
  # If there's no default.cfg, it returns a as that's the one we booted anyway,
  # since it's first in the boot order.
  defp read_boot_slot do
    case :file.read_file(@boot_config_path) do
      {:ok, cfg } ->
        Logger.info "CONFIG READ: #{inspect cfg}"
        cfg_to_slot(cfg)
      _ ->
        Logger.error "#{@boot_config_path} is missing!"
        :a
    end
  end


  ############################# Hub Interface ################################

  import Application, only: [get_env: 3]

  @service_pt   [:services, :firmware]
  @point          [:sys, :firmware]
  @current_pt     @point ++ [:current]
  @update_pt      @point ++ [:update]
  
  @app_id        get_env :firmware, :app_id,      "unknown"
  @repo          get_env :firmware, :repo,        "unknown"
  @branch        get_env :firmware, :branch,      "unknown"
  @update_repo   get_env :firmware, :update_repo,  @repo
  @update_branch get_env :firmware, :update_branch,@branch
  

  defp attach_to_hub(fw_state) do
    setup_sys_firmware(fw_state)
    setup_service_firmware(fw_state)
    Hub.master @current_pt
  end
      
  # PRIVATE HELPER FUNCTIONS
  
  defp setup_sys_firmware(fw_state) do
    Hub.put @point ++ [:current], current_fwinfo(fw_state)
    Hub.put @point ++ [:update],  update_fwinfo
  end
  
  defp setup_service_firmware(fw_state) do
    current = Dict.take(current_fwinfo(fw_state),
                        [:version, :date, :status, :update_url])
    update = Dict.take(update_fwinfo, [:update_url])
    fwinfo = [
                current: Hub.pt_to_url(@point ++ [:current]),
                location: Hub.pt_to_url(@point),
                "@type": "firmware",
                status: "online",
                info: current ++ update
               ]
    Hub.put @service_pt, fwinfo
  end

  defp current_fwinfo(fw_state), do: [
      app_id:   @app_id,
      version:  get_env(@app_id, :firmware_version, "unknown"),
      date:     get_env(@app_id, :firmware_date, "unknown"),
      branch:   @branch,
      repo:     @repo,
      status:   fw_state.status,
      slot:     fw_state.slot
  ]

  defp update_fwinfo, do: [
      app_id:       @app_id,
      branch:       @update_branch,
      repo:         @update_repo,
      policy:       :external,
      update_url:   Enum.join(
        [@update_repo, @app_id, @update_branch], "/"
        ) <> ".fw"
  ]
  
  @doc "Handle a request to normalize (accept) firmware"
  def handle_call({:request, @current_pt, [status: "normal"], _}, _, state) do
    case state.status do
      :provisional ->
        #Logger.info "switching provisional firmware to normal"
        write_boot_config state.slot, false
        update_and_reply_to_status_change(state, :normal)
      :normal ->
        {:reply, :nochange, state}
      :faulty ->
        {:reply, :nochange, state}
    end
  end

  @doc "Handle a request to normalize (accept) firmware"
  def handle_call({:request, @current_pt, [status: "provisional"], _}, _, state) do
    case state.status do
      :normal ->
        new_slot = [ b: :a, a: :b ][state.slot]
				write_boot_config new_slot, false
        update_and_reply_to_status_change(state, :provisional)
      _ ->
        {:reply, :nochange, state}
    end
  end

  # helper that updates the current firmware status in all places neede
  defp update_and_reply_to_status_change(state, new_status) do
    new_state = Dict.merge(state, [status: new_status])
    Hub.put @service_pt ++ [:info], status: new_status
    reply = Hub.update(@current_pt, status: new_status)
    {:reply, reply, new_state}
  end
 
 
  ######################### Cowboy interface ##############################

  @doc """
  Used by a webserver/cowboy to accept new firmware via HTTP.

  Once firmware is streamed, it returns success (2XX) or failure (4XX/5XX).
  Calls `update_status()` to reflect status at `/sys/firmware`.
  Won't let you upload firmware on top of provisional (returns 403)
  
  TODO Config.get below needs to become a Genserver.call I think
  """
  def upload_acceptor(req, state) do
    case Config.get :firmware_status do
      :provisional ->
        {:halt, :cowboy_req.reply(403, [], req), state}
      _ ->
				 accept_and_validate_firmware(req, state)
		end
  end

  # called if we're in nonprovisional mode and we want to accept an
  # update to the firwmare.  uploads the new firmware and then decides
  # what to do with it.
  defp accept_and_validate_firmware(req, state) do
		update_status_during_install :uploading
		Logger.info "streaming firmware upload"
		File.open!(@fw_zip_path, [:write], &(stream_fw &1, req))
		Logger.info "upload complete, validating firmware"
		update_status_during_install :validating
		zip_charlist = String.to_char_list(@fw_zip_path)
		{:ok, fw_handle} = :zip.zip_open zip_charlist, [:memory]
		{:ok, {_, fw_json}} = :zip.zip_get 'firmware.json', fw_handle
		:zip.zip_close fw_handle
    # REVIEW: firmware_valid? was moved to plugin, but not accessible yet
    # due to lack of true state and genserver
    fw_spec = :jsx.decode fw_json, labels: :atom
    #if firmware_valid?(fw_spec, zip_charlist) do
			spawn fn -> install_firmware(fw_spec, true) end
			{true, req, state}
    # else
    #   update_status :error, error: :invalid_firmware
    #   {:halt, :cowboy_req.reply(400, [], req), state}
    # end
  end


  @max_upload_chunk 100000        # 100K max chunks to keep memory reasonable
  @max_upload_size  100000000     # 100M max file to avoid using all of flash

  # that likely uses PLUG, and can be plugged in through genserver state
  # streams the firmware from HTTP body in cowboy into the given (opened) file
  defp stream_fw(f, req, count \\ 0) do
    Hub.update @point ++ [:update], bytes_uploaded: count
    if count > @max_upload_size do
      update_status_during_install :error, 
        error_message: "the uploaded firmware file is too large"
      {:error, :too_large}
    else # still have room left
      case :cowboy_req.body(req, [:length, @max_upload_chunk]) do
        {:more, chunk, new_req} ->
          :ok = IO.binwrite f, chunk
          stream_fw(f, new_req, (count + byte_size(chunk)))
        {:ok, chunk, new_req} ->
          :ok = IO.binwrite f, chunk
          {:done, new_req}
      end
    end
  end
  
  ########################## actual firmware updater ########################

  # configuration for firmware update staging file area

  # assumes firmware is for this device and valid, and install it.
  #@spec install_firmware(fw_spec, [:a|:b], [true|false]) :: :ok
  # REVIEW: calls to update_status below do not really update the state,
  #         just the public status
  
  defp install_firmware(fw_spec, restart?) do
    if @flash_on_update, do: Leds.set(@flash_on_update, :fastblink)
    new_slot = [ b: :a, a: :b ][read_boot_slot()]
    Logger.info "installing firmware into slot '#{new_slot}'"
    slot_str = Atom.to_string(new_slot)
    update_status_during_install :installing,
        version: fw_spec[:version],
        date: fw_spec[:date], slot: new_slot,
        device: @rootfs_partition[new_slot]
    Logger.info "installing rootfs @ #{@rootfs_partition[new_slot]}"
    :ok = exec "unzip -p #{@fw_zip_path} data/rootfs.img | dd of=#{@rootfs_partition[new_slot]}"
    Logger.info "installing kernel..."
    :ok = exec "unzip -p #{@fw_zip_path} data/bzImage > /boot/bzImage.#{slot_str}"
    update_status_during_install :configuring
    write_boot_config(new_slot, true)
    Logger.info "update complete"
    if restart? do
      Logger.info "restarting..."
      :ok = exec "umount /boot"
      update_status_during_install :restarting
      :timer.sleep 1
      :erlang.halt
    end
  end

  # mark the boot configuration so that the NEXT boot will boot from the
  # specified slot.   If "provisional" is set then the next boot will be
  # provisional (i.e. will fallback to current slot upon reboot unless
  # validated somehow to be not-provisional).
  defp write_boot_config(slot, provisional) do
    if provisional do
      Logger.info "backing up boot config (next boot will be provisional)"
      # File does not exist on the first update so check if exists
      if File.exists?(@boot_config_path) do
        File.copy!(@boot_config_path, @fallback_config_path)
      else
        write_initial_fallback
      end
    end
    Logger.info "writing config to (next boot of slot #{slot})"
    write_config_file(slot)
    sync_disk
  end

  # set the update status in a convenient way
  defp update_status_during_install(status, other \\ []) do
    Hub.update @point ++ [:update], Dict.merge([status: status], other)
    Hub.update @service_pt ++ [:info], Dict.merge([status: status], other)
  end

  defp exec(cmd) do
    os_cmd(cmd)
    :ok
  end
end
