# CHANGELOG

## v0.1.0 (April 20, 2015)

- broke out from echo project as a separate project
- changed license to MIT
- removed firmware_valid? for now (needs to be plugin later)
- removed macros in favor of functions
- added configuration option for @flash_led_on_update
- refactored code to make it a genserver
- added TODO.md to keep track of intended work
- removed dependencies on :ets in favor of configs and state in genserver
- change default booatloader/config to be uboot not syslinux

