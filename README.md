Firmware
========

Handles firmware initialization and upgrades, dealing with flash storage, etc.

## STILL UNDERGOING  MAJOR CHANGES!

As of April 20, 2015, this project contains code recently extracted from a proprietary device, and is in the process of being cleaned up.   It still has some major dependencies and architectural problems as a standalone project.

Unlike most cellulose projects, _firmware_ still has strong dependencies on the Hub module (for instance) and cowboy that are inseparable at this point.  This will hopefully change soon.

## Hub Integration

Publishes information at the following hub locations:

    /services/firmware            description of firmware service
    /sys/firmware                 primary status and functionality
    /sys/firmware/current         information about the current firmware
    /sys/firwmare/update          information about "updating" firwmare

## Configuration

There are three 

You can configure firmware through elixir's configuration system (config.exs).

```elixir
    # config.exs
    configure :firmware, bootloader: :uboot,
      rootfs_partitions: [a: "/dev/mmcblk0p2", b: "/dev/mmcblk0p3"],
      boot_config_path: "/boot/uEnv.txt",
      boot_fallback_path: "/boot/uEnv_fallback.txt",
      flash_on_update: :power
```

 key | type | description
:----|:-----|:------------
`flash_on_update` | atom | The atom of the LED to blink upon firmware update.  If present, the  LED module must be present and support the "flastblink" mode.
`bootloader` | atom | Currently, must be either `:syslinux` (for x86 configs) or `:uboot` (for ARM devices)
`app_id` | atom | MUST match the application id or no config version/date will be used.  This is the key passed to get_env to get the firmware_version and firmware_date keys (see below on version stamping)
`rootfs_partitions` | dict | see example above
`boot_config_path`  | string | path to boot config file (docs not yet written)
`boot_fallback_path`  | string | path to fallback config file (docs not yet written
`repo` | string | The update repo for automatic firmware updates (NYI)
`branch` | string | The branch name for automatic updates (NYI)
`update_repo` | string | The update repo for automatic firmware updates (NYI)
`update_branch` | string | The branch name for automatic updates (NYI)

## version/date stamping

In your application's envionrment, you can define firmware_version and firmware_date, and they will get reported by the firmware.  This allows you to timestamp your firmware with a build environment variable like this..

      # partial from your app's mix.exs
      def application, do: [ 
          ....
          env: [ 
            firmware_version: System.get_env("BUILD_VER"),
            firmware_date:    System.get_env("BUILD_DATE"),
      ]


    
    
    