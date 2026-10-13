# RTKBase

### An easy to use and easy to install web frontend with bash scripts and services for a simple headless gnss base station.

## FrontEnd:
|<img src="./images/web_status.png" alt="status" width="250"/>|<img src="./images/web_settings.png" alt="settings" width="250"/>|<img src="./images/web_logs.png" alt="logs" width="250"/>|

Frontend's main features are:

+ View the satellites signal levels
+ View the base location on a map
+ Detect and configure the Gnss receiver (Ublox F9P, Septentrio Mosaic-X5, Unicore UM980 / UM982)
+ Start/stop various services (Sending data to a Ntrip caster, internal Ntrip caster, Rtcm server, Sending Rtcm stream on a radio link, Log raw data to files)
+ Edit the services settings
+ Convert raw data to Rinex
+ Download/delete raw data

## Base example:
<img src="./images/base_f9p_raspberry_pi.jpg" alt="status" width="550" />

+ Enclosure: GentleBOX JE-200 (waterproof, cable glands for antenna and ethernet cable)
+ SBC: Raspberry Pi 3 / Orange Pi Zero (512MB)
+ Gnss Receiver: U-Blox ZED-F9P (from Drotek)
+ Antenna: DA910 (Gps L1/L2, Glonass L1/L2, Beidou B1/B2/B3 and Galileo E1/E5b/E6) + sma (male) to TNC (male) outdoor cable.
+ Power: Trendnet TPE-115GI POE+ injector + Trendnet POE TPE-104GS Extractor/Splitter + DC Barrel to Micro Usb adapter

Other images are available in the ./images folder.

## Ready to flash release:
A ready to flash Armbian image is available for Raspberry Pi, Orange Pi Zero, Orange Pi Zero 2, Orange Pi Zero 3 SBC : [Armbian_RTKBase](https://github.com/Stefal/build/releases/latest)

For older Raspberry Pi releases, see [here](https://github.com/jancelin/pi-gen/releases/latest).

## Installation (field station):
Install on office WiFi; the station then works as soon as it is powered up in the field. Run every command as the normal user (e.g. `griuser`), over SSH. RTKBase ends up in `~/rtkbase`.

1. **Flash** Raspberry Pi OS Lite (64-bit) with Raspberry Pi Imager. In the advanced settings set a unique hostname (e.g. `gripi003`, it is used in uploaded file names and in Tailscale), user/password, SSH, the office WiFi (country NZ) and the time zone.

2. **Connect** the GNSS receiver (F9P or UM980), and the DS18B20 if the station has one. The LTE modem and the MPPT adapter are optional at this point, they are detected at every boot.

3. **Install** (from the home directory, this is where `rtkbase` gets cloned):

   ```bash
   cd ~
   wget https://raw.githubusercontent.com/xandercai/rtkbase/master/tools/install.sh -O install.sh
   chmod +x install.sh
   sudo ./install.sh --all repo --rtkbase-repo master
   ```

   Waveshare SIM7600 only, the first time a modem is used (switches it to ECM mode, stored in the modem): connect it and run `sudo ~/rtkbase/tools/install.sh --detect-modem`. Not needed for the Teltonika.

4. **Storage** (data in RAM, persistent journal):

   ```bash
   sudo ~/rtkbase/mount_tmpfs.sh
   ```

5. **Tailscale**: `sudo systemctl start tailscaled && sudo tailscale up` and log in (on a master, tailscaled is stopped whenever the LTE modem is in airplane mode; the login is kept). Then disable key expiry for the machine in the Tailscale admin console. If you use flags (e.g. `--ssh`), put the same ones in `tailscale_up_flags` in `~/rtkbase/settings.conf`.

6. **rclone**, without sudo: either copy `~/.config/rclone/rclone.conf` from a working station, or run `rclone config` and create a Google Drive remote named `gdrive` (use `rclone authorize "drive"` on a PC for the browser step). Check with `rclone lsd gdrive:`.

7. Optional, **phone hotspot** for SSH on site (the phone doesn't need to be on):

   ```bash
   sudo nmcli connection add type wifi con-name hotspot ifname wlan0 ssid "<ssid>" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "<password>"
   ```

8. Only for a **master/client pair** sharing one LTE modem: set `lte_online_minutes='15'` in `~/rtkbase/settings.conf` on both, then:

   ```bash
   sudo ~/rtkbase/tools/install.sh --unit-files
   ```

9. **Reboot and check**, with the GNSS antenna seeing the sky:

   ```bash
   sudo reboot
   ```

   Wait 2-3 minutes after the reboot (role detection waits up to a minute for a modem), log in again and run:

   ```bash
   ~/rtkbase/tools/field_check.sh
   ```

   Fix every FAIL until it prints `Ready for the field.`

10. **Deploy**: `sudo poweroff`, connect everything on site (for a pair, an ethernet cable between the two Pis), power on.

The LTE modem, the MPPT adapter and the master/client role are detected at every boot (see the `[network]` section of settings.conf). WiFi is always preferred over LTE when it has internet. The web UI is disabled by default (`web_ui_enabled`).

## Updating an existing station:
Older settings.conf files keep `web_ui_enabled='1'`: set it to `'0'` first to turn the web UI off.

```bash
git -C ~/rtkbase checkout -- unit/
git -C ~/rtkbase pull
sudo ~/rtkbase/tools/install.sh --dependencies --rtkbase-requirements --unit-files --gpsd-chrony --start-services
sudo ~/rtkbase/mount_tmpfs.sh
sudo reboot
```

The first line drops the timer files that older versions of copy_unit.sh rewrote in place, otherwise `git pull` refuses to update. After the reboot, run `~/rtkbase/tools/field_check.sh`.

## Manual installation: 
The `install.sh` script can be used without the `--all` option to split the installation process into several different steps:
```
    ################################
    RTKBASE INSTALLATION HELP
    ################################
    Bash scripts to install a simple gnss base station with a web frontend.
    
    
    
    * Before install, connect your gnss receiver to raspberry pi/orange pi/.... with usb or uart.
    * Running install script with sudo
    
    Easy installation: sudo ./install.sh --all release
    
    Options:
            -a | --all <rtkbase source>
                             Install all you need to run RTKBase : dependencies, RTKlib, last release of Rtkbase, services,
                             crontab jobs, detect your GNSS receiver and configure it.
                             <rtkbase source> could be:
                                 release  (get the latest available release)
                                 repo     (you need to add the --rtkbase-repo argument with a branch name)
                                 url      (you need to add the --rtkbase-custom-source argument with an url)
                                 bundled  (available if the rtkbase archive is bundled with the install script)
    
            -u | --user
                             Use this username as User= inside service unit and for path to rtkbase:
                             --user=john will install rtkbase in /home/john/rtkbase
    
            -d | --dependencies
                             Install all dependencies like git build-essential python3-pip ...
    
            -r | --rtklib
                             Get RTKlib 2.4.3b34j from github and compile it.
                             https://github.com/rtklibexplorer/RTKLIB/tree/b34j
    
            -b | --rtkbase-release
                             Get last release of RTKBase:
                             https://github.com/Stefal/rtkbase/releases
    
            -i | --rtkbase-repo <branch>
                             Clone RTKBASE from github with the <branch> parameter used to select the branch.
    
            -j | --rtkbase-bundled
                             Extract the rtkbase files bundled with this script, if available.
    
            -f | --rtkbase-custom <source>
                             Get RTKBASE from an url.
    
            -t | --unit-files
                             Deploy services.
    
            -g | --gpsd-chrony
                             Install gpsd and chrony to set date and time
                             from the gnss receiver.
    
            -e | --detect-gnss
                             Detect your GNSS receiver.
    
            -n | --no-write-port
                             Doesn'\''t write the detected port inside settings.conf.
                             Only relevant with --detect-gnss argument.
    
            -c | --configure-gnss
                             Configure your GNSS receiver.
    
            -s | --start-services
                             Start services (rtkbase_web, str2str_tcp, gpsd, chrony)
    
            -h | --help
                              Display this help message.
   ```

So, if you really want it, let's go for a manual installation with some explanations:

1. Install dependencies with `sudo ./install.sh --dependencies`, or do it manually with:
   ```bash
    sudo apt update
    sudo apt install -y  git build-essential pps-tools python3-pip python3-dev python3-setuptools python3-wheel libsystemd-dev bc dos2unix socat zip unzip pkg-config psmisc
   ```

1. Install RTKLIB with `sudo ./install.sh --rtklib`, or:
   + get [RTKlib](https://github.com/rtklibexplorer/RTKLIB)

      ```bash
      cd ~
      wget -qO - https://github.com/rtklibexplorer/RTKLIB/archive/refs/tags/b34j.tar.gz | tar -xvz
      ```

   + compile and install str2str:

      Optionally, you can edit the CTARGET line in makefile in RTKLIB/app/str2str/gcc
      
      ```bash
      cd RTKLIB/app/str2str/gcc
      nano makefile
      ```
      
      For an Orange Pi Zero SBC, i use:
      
      ``CTARGET = -mcpu=cortex-a7 -mfpu=neon-vfpv4 -funsafe-math-optimizations``
      
      Then you can compile and install str2str:
      
      ```bash  
      make
      sudo make install
      ```
   + Compile/install `rtkrcv` and `convbin` the same way as `str2str`.

1. Get latest rtkbase release `sudo ./install.sh --rtkbase-release`, or:
   ```bash
   wget https://github.com/stefal/rtkbase/releases/latest/download/rtkbase.tar.gz -O rtkbase.tar.gz
   tar -xvf rtkbase.tar.gz

   ```
   If you prefer, you can clone this repository to get the latest code.

1. Install the rtkbase requirements:
   ```bash
   python3 -m pip install --upgrade pip setuptools wheel  --extra-index-url https://www.piwheels.org/simple
   python3 -m pip install -r rtkbase/web_app/requirements.txt  --extra-index-url https://www.piwheels.org/simple

1. Install the systemd services with `sudo ./install.sh --unit-files`, or do it manually with:
   + Edit them (`rtkbase/unit/`) to replace `{user}` with your username.
   + If you log the raw data inside the base station, you may want to compress these data and delete the too old archives. `archive_and_clean.sh` will do it for you. The default settings compress the previous day data and delete all archives older than 90 days. To automate these 2 tasks, enable the `rtkbase_archive.timer`. The default value runs the script every day at 04H00.
   + Copy these services to `/etc/systemd/system/` then enable the web server, str2str_tcp and rtkbase_archive.timer:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable rtkbase_web
   sudo systemctl enable str2str_tcp
   sudo systemctl enable rtkbase_archive.timer
   ```
1. Install and configure chrony and gpsd with `sudo ./install.sh --gpsd-chrony`, or:
   + Install chrony with `sudo apt install chrony` then add this parameter in the chrony conf file (/etc/chrony/chrony.conf):
   
      ```refclock SHM 0 refid GPS precision 1e-1 offset 0.2 delay 0.2```
   
     Edit the chrony unit file. You should set `After=gpsd.service`
   + Install a gpsd release >= 3.2 or it won't work with a F9P. Its conf file should contains:
   ```
      # Devices gpsd should connect to at boot time.
      # They need to be read/writeable, either by user gpsd or the group dialout.
      DEVICES="tcp://localhost:5015"

      # Other options you want to pass to gpsd
      GPSD_OPTIONS="-n -b"

   ```
   Edit the gpsd unit file. You should have something like this in the "[Unit]" section: 
   ```
      [Unit]
      Description=GPS (Global Positioning System) Daemon
      Requires=gpsd.socket
      BindsTo=str2str_tcp.service
      After=str2str_tcp.service
   ```
   + Reload the services and enable them:
   ```bash
      sudo systemctl daemon-reload
      sudo systemctl enable chrony
      sudo systemctl enable gpsd
   ```

1. Install the avahi service definition with `sudo ./install.sh --zeroconf`, or:
   + Copy the `rtkbase_web.service` file from `rtkbase/tools/zeroconf/` directory to `/etc/avahi/services/`
   + Replace `{port}` with the port number used by the web server (e.g. 80).  

1. Connect your gnss receiver to raspberry pi/orange pi/.... with usb or uart, and check which com port it uses (ttyS1, ttyAMA0, something else...). If it's a U-Blox F9P receiver (usb or uart) or a Septentrio Mosaic-X5 (usb), you can use `sudo ./install.sh --detect-gnss`. Write down the result, you may need it later.

1. If you didn't have already configure your gnss receiver, you must set it to output raw or rtcm3 data:
   
   If it's a U-Blox ZED-F9P (usb or uart), or a Septentrio Mosaic-X5 (usb), or a Unicore UM980/UM982 you can use 
   ```bash
   sudo ./install.sh --detect-gnss --configure-gnss
   ```
     
   If you need to use a config tool from another computer (like U-center), you can use `socat`:

   ```bash
   sudo socat tcp-listen:128,reuseaddr /dev/ttyS1,b115200,raw,echo=0
   ```
   
   Change the ttyS1 and 115200 value if needed. Then you can use a network connection in U-center with the base station ip address and the port n°128.

1. Now you can start the services with `sudo ./install.sh --start-services`, or:
   ```bash
   sudo systemctl start rtkbase_web
   sudo systemctl start str2str_tcp
   sudo systemctl start gpsd
   sudo systemctl start chrony
   sudo systemctl start rtkbase_archive.timer
   ```

   Everything should be ready, now you can open a web browser to your base station ip address.

## How it works:
RTKBase use several RTKLIB `str2str` instances started with `run_cast.sh` as systemd services. `run_cast.sh` gets its settings from `settings.conf`
+ `str2str_tcp.service` is the main instance. It is connected to the gnss receiver and broadcast the raw data on TCP for all the others services.
+ `str2str_ntrip_A.service` get the data from the main instance, convert the data to rtcm and stream them to a Ntrip caster.
+ `str2str_ntrip_B.service` get the data from the main instance, convert the data to rtcm and stream them to another Ntrip caster.
+ `str2str_local_ntrip_caster.service` get the data from the main instance, convert the data to rtcm, and act as a local Ntrip caster.
+ `str2str_rtcm_svr.service` get the data from the main instance, convert the data to rtcm and stream them to clients
+ `str2str_rtcm_serial.service` get the data from the main instance, convert the data to rtcm and stream them to a serial port (radio link, or other peripherals)
+ `str2str_file.service` get the data from the main instance, and log the data to files.

<img src="./images/internal.png" alt="internal"/>

The web GUI is available when the `rtkbase_web` service is running.

## Advanced:
+ Offline base station without U-Blox receiver, how to get date and time:
If gpsd can't understand the raw data from your gnss receiver, you can enable the raw2nmea service. It will convert the raw data to the tcp port set in `settings.conf` (nmea_port) and gpsd will use it to feed chrony. `systemctl enable --now rtkbase_raw2nmea`
+ Aerial images:
The default map background is OpenStreetMap, but you can switch to a worldwide aerial layer if you have a Maptiler key. To enable this layer, create a free account on [Maptiler](https://www.maptiler.com/), create a key and add it to `settings.conf` inside the `[general]` section:
`maptiler_key=your_key`
+ Receiver options: str2str accept some receiver dependent options. If you use a U-Blox, the `-TADJ=1` parameter is recommended as a workaround to non-rounded second values in Rtcm and Ntrip outputs. You can enter this parameter inside the settings forms. More information [here](https://rtklibexplorer.wordpress.com/2017/02/01/a-fix-for-the-rtcm-time-tag-issue/) and [here](https://github.com/Stefal/rtkbase/issues/80).

    <img src="./images/ntrip_settings.png" alt="status" width="450"/>
## Development release:
If you want to install RTKBase from the dev branch, you can do it with these commands:
```bash
cd ~
wget https://raw.githubusercontent.com/Stefal/rtkbase/dev/tools/install.sh -O install.sh
chmod +x install.sh
sudo ./install.sh --all repo --rtkbase-repo dev
```

## Other usages:
A gnss receiver with a timepulse output is a very accurate [stratum 0](https://en.wikipedia.org/wiki/Network_Time_Protocol#Clock_strata) clock thus, your gnss base station could act as a stratum 1 ntp peer for your local network and/or the [ntp pool](https://en.wikipedia.org/wiki/NTP_pool). There are a few steps to do this:

+ Connect the timepulse output + GND to some GPIO inputs on your SBC.
+ Configure this input as PPS in your operating system.

   + Raspberry Pi example: 
      + Inside /boot/config.txt, add `dtoverlay=pps-gpio,gpiopin=18` on a new line. '18' is the input used for timepulse.
      + Inside /etc/modules, add `pps-gpio` on a new line, if it is not already present.

   + Orange Pi Zero example, inside /boot/armbianEnv.txt: 
      
      + Add `pps-gpio` to the `overlays` line.
      + One a new line, add `param_pps_pin=PA19` <- change 'PA19' to your input.

+ Set gpsd and chrony to use PPS

   + gpsd: comment the `DEVICE` line in `/etc/defaut/gpsd` and uncomment `#DEVICES="tcp:\\127.0.0.1:5015 \dev\pps0`. Edit the port if you use the rtkbase_raw2nmea service.

   + chrony: inside `/etc/chrony/chrony.conf` uncomment the refclock pps line  and add noselect to the 'refclock SHM 0`. You should have something like this:
   ```
      refclock SHM 0 refid GPS precision 1e-1 offset 0 delay 0.2 noselect
      refclock PPS /dev/pps0 refid PPS lock GPS
   ```

   + reboot your sbc and check the result of `chronyc sources -v` You should read something like this, notice the '*' before 'PPS': 
   ```
      basegnss@orangepizero:~$ chronyc sources -v
      210 Number of sources = 6
      .-- Source mode  '^' = server, '=' = peer, '#' = local clock.
      / .- Source state '*' = current synced, '+' = combined , '-' = not combined,
      | /   '?' = unreachable, 'x' = time may be in error, '~' = time too variable.
      ||                                                 .- xxxx [ yyyy ] +/- zzzz
      ||      Reachability register (octal) -.           |  xxxx = adjusted offset,
      ||      Log2(Polling interval) --.      |          |  yyyy = measured offset,
      ||                                \     |          |  zzzz = estimated error.
      ||                                 |    |           \
      MS Name/IP address         Stratum Poll Reach LastRx Last sample
      ===============================================================================
      #? GPS                           0   4   377    17    +64ms[  +64ms] +/-  200ms
      #* PPS                           0   4   377    14   +363ns[ +506ns] +/- 1790ns
      ^- ntp0.dillydally.fr            2   6   177    16    -12ms[  -12ms] +/-   50ms
      ^? 2a01:e35:2fba:7c00::21        0   6     0     -     +0ns[   +0ns] +/-    0ns
      ^- 62-210-213-21.rev.poneyt>     2   6   177    17  -6488us[-6487us] +/-   67ms
      ^- kalimantan.ordimatic.net      3   6   177    16    -27ms[  -27ms] +/-   64ms

   ```
## Requirements:
Debian base distro >= 12 (Bookworms)
Python >= 3.11

## History:
See the [changelog](./CHANGELOG.md)

## License:
RTKBase is licensed under AGPL 3 (see [LICENSE](./LICENSE) file).

RTKBase uses some parts of other software:
+ [RTKLIB-EX](https://github.com/rtklibexplorer/RTKLIB) (BSD-2-Clause)
+ [ReachView](https://github.com/emlid/ReachView) (GPL v3)
+ [Flask](https://palletsprojects.com/p/flask/) [Jinja](https://palletsprojects.com/p/jinja/) [Werkzeug](https://palletsprojects.com/p/werkzeug/) (BSD-3-Clause)
+ [Flask SocketIO](https://github.com/miguelgrinberg/Flask-SocketIO) (MIT)
+ [Bootstrap](https://getbootstrap.com/) [Bootstrap Flask](https://github.com/greyli/bootstrap-flask) [Bootstrap 4 Toggle](https://gitbrent.github.io/bootstrap4-toggle/) [Bootstrap Table](https://bootstrap-table.com/) (MIT)
+ [wtforms](https://github.com/wtforms/wtforms/) (BSD-3-Clause) [Flask WTF](https://github.com/lepture/flask-wtf) (BSD)
+ [pystemd](https://github.com/facebookincubator/pystemd) (L-GPL 2.1)
+ [gpsd](https://gitlab.com/gpsd/gpsd) (BSD-2-Clause)

RTKBase uses [OpenStreetMap](https://www.openstreetmap.org) tiles. Thank you to all the contributors!
