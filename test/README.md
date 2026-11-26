# Local-host image

This is a livecd for https://github.com/Frontrider/minimal-self-host. Will automatically start the compose stack on boot. If you don't fully understand what you're doing simply rebooting the computer will update the servers if anything is available. The host still needs to be update separately, a software manager is provided for that.

Built on top of manjaro for stability, with an i3 tiling desktop for lower overhead. This image tries to be somewhat ergonomic (not fully!), while understanding that a fully fledged desktop is not needed for a server's deployment. Ideally you won't use more than the browser, and you'll only use it once a month at best.

Contains a falkon browser(low overhead), a file manager, a terminal emulator, a task manager (can be used for simple monitoring), and a NetworkManager applet for Wi-Fi. The live session also includes GParted for preparing disks; it is not installed on the target system.
# Usage

Burn the image to a pendrive (we recommend rufus on windows, SUSE studio image writer for linux), boot from it then follow the installer.

On the live image the installer starts automatically as root. If you cancel it, the i3 bar Installer button or Super+I starts it again.

The i3 bar buttons also have Super + first letter bindings: Super+M menu, Super+I installer, Super+B backups (opens the NPBackup GUI), Super+F Falkon, Super+T terminal, Super+P processes, Super+L lock, Super+R reboot and Super+S shutdown. The application menu and window switcher use the Adapta-Nokto rofi theme.

The live ISO autologins; installed systems boot to the LightDM login screen.

On laptops, closing the lid stops LightDM and the X server; opening the lid starts them again. The live installer ignores lid events so an installation is not interrupted. This can give you a little more headroom when you don't use the gui.

After installation open the anywherelan control panel with the browser (a button is available on the bar for it), then pair your other devices. Do give it 2-5 minutes after boot because it has to download the docker images that run the core of the system, and it will also not work if the wifi is not available yet. You have graphical tools to connect to any wifi if the computer can do that.

# Installation

This is a manjaro based live cd, releases contain the iso you can download.

Manjaro hello has been reconfigured to help you set up extra stroage and automatic backups (via restic and a gui for it).
IF you don't touch anything, backups will happen at midnight then a technician can help you recover from there.
Backup the contents of `/etc/local-host` on a separate drive, it has the recovery keys you need to restore the backups.

After installation, you should connect it to the internet as soon as possible so it can pull the server images that it needs to work.

As soon as there is internet after the first install/every reboot the system downloads/updates the server software that it is running.