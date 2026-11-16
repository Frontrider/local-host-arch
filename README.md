# Local-host image

This is a livecd for https://github.com/Frontrider/minimal-self-host. Will automatically start the compose stack on boot. 
If you don't fully understand what you're doing simply rebooting the computer will update the servers if anything is available. The host still needs to be update separately, a software manager is provided for that.

Built on top of manjaro for stability, with an i3 tiling desktop for lower overhead.
This image tries to be somewhat ergonomic (not fully!), while understanding that a fully fledged desktop is not needed for a server's deployment. Ideally you won't use more than the browser, and you'll only use it once a month at best.

Contains a falkon browser(low overhead), a file manager, a terminal emulator, a task manager (can be used for simple monitoring), and a NetworkManager applet for Wi-Fi.

# Usage

Burn the image to a pendrive (we recommend rufus on windows, SUSE studio image writer for linux), boot from it then follow the installer.

The live ISO autologins; installed systems boot to the LightDM login screen.

On laptops, closing the lid stops LightDM and the X server; opening the lid starts LightDM again. The live installer ignores lid events so an installation is not interrupted.

After installation open the anywherelan control panel with the browser (a button is available on the bar for it), then pair your other devices. Do give it 2-5 minutes after boot because it has to download the docker images that run the core of the system, and it will also not work if the wifi is not available yet.

The awl url of this device (local-host.awl by default) will get you to a simple application manager, that you can use to deploy what you need.
Every service is pre-configured to work out of the box with as few settings as possible. The awl domain is not available on the host, currently this is by design due to the internals of the tools that manage the deployments and the connectivity to the server.


Every service that we recommend using is marked as such.

# Storage

`/data` is a plain directory on the root filesystem. The image does not detect
or mount disks automatically; the compose stack binds its `localhost_data`
volume to `/data`.

If the data should live on a separate disk, mount that disk on `/data` yourself
(for example in `/etc/fstab` or with a systemd mount unit). The image never
mounts or unmounts anything under `/data`; an existing mount is used as-is.

This folder wil be owned by the user 1000:1000 (uid:guid), the container will automatically set up this ownership.


# Notes

Nextcloud is a part of the application list, but I don't recommend using it for one reason. It does not like it when the storage it is attached to is written to by other services and it is also quite heavy.