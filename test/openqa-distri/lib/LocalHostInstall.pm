package LocalHostInstall;

use strict;
use warnings;
use Exporter 'import';
use testapi;

our @EXPORT_OK = qw(install_system);

sub click_offset {
    my ($match, $x_offset, $y_offset) = @_;
    my $area = $match->{area}->[-1];
    mouse_set($area->{x} + $x_offset, $area->{y} + $y_offset);
    mouse_click;
    mouse_hide;
}

sub configure_storage {
    my ($disks, $backup, $backup_fs, $raid) = @_;
    my $storage = assert_screen('storage-drives-page');
    # Asset labels differ from the captured disks. Use the checkbox column
    # and the 34 px row spacing; the first extra disk is at (216, 232).
    for my $index (0 .. $disks - 1) {
        click_offset($storage, 15, 150 + 34 * $index);
    }
    assert_and_click('storage-drives-next');

    assert_screen('review-storage-page');
    if ($backup) {
        # The first device is one radio row below "No backup drive". Anchor
        # to that label rather than checking for the reference disk's name.
        my $no_backup = assert_screen('review-storage-no-backup-drive');
        click_offset($no_backup, -10, 35);
        my $backup_filesystem = assert_screen('review-storage-backup-filesystem');
        # F2FS is the second option in this group (not the one for /data).
        click_offset($backup_filesystem, 15, 64) if $backup_fs eq 'f2fs';
    }

    if ($raid eq 'RAID0') {
        # This suite has exactly two data disks. The first RAID option is
        # RAID1, and RAID0 is the next row, below RAID1's one-line help.
        # Verification checks the installed Btrfs profiles, not just fstab.
        my $data = assert_screen('review-storage-data-heading');
        click_offset($data, 15, 169);
    }
    assert_and_click('review-storage-next');
}

sub configure_webdav {
    my ($folder) = @_;

    assert_and_click('second-backup-enable', mousehide => 1);
    assert_and_click('second-backup-on-backup-drive', mousehide => 1);
    assert_and_click('second-backup-remote-local-only', mousehide => 1);
    # The provider list starts at local only, then Drive, OneDrive, WebDAV.
    send_key 'down' for 1 .. 3;
    send_key 'ret';
    assert_screen('second-backup-remote-webdav');

    assert_and_click('second-backup-remote-folder', mousehide => 1);
    send_key 'ctrl-a';
    type_string($folder);
    assert_and_click('second-backup-webdav-url', mousehide => 1);
    type_string('http://10.0.2.2:8081');
    assert_and_click('second-backup-webdav-username', mousehide => 1);
    type_string('openqa');
    assert_and_click('second-backup-webdav-password', mousehide => 1);
    type_password('openqa-test');
}

sub install_system {
    my ($disks, $backup, $backup_fs, $raid, $webdav_folder) = @_;

    assert_and_click('welcome-next');
    assert_screen('time-zone-region');
    assert_and_click('time-zone-next');
    assert_screen('keyboard-model');
    assert_and_click('keyboard-next');
    assert_screen('system-drive-page');
    assert_and_click('system-drive-next');

    configure_storage($disks, $backup, $backup_fs, $raid);

    # Leave the second backup disabled except in the WebDAV suite.
    assert_screen('second-backup-page');
    configure_webdav($webdav_folder) if defined $webdav_folder;
    assert_and_click('calamares-next');

    my $users = assert_screen('user-name');
    click_lastmatch(mousehide => 1);
    type_string('openqa');

    # The two password pairs have identical placeholders. Use coordinates
    # relative to the matched Users page, not a repeated image of a field.
    for my $x_offset (72, 287) {
        click_offset($users, $x_offset, 173);
        type_password('openqa');
    }
    assert_and_click('user-autologin', mousehide => 1);
    assert_and_click('user-next');

    assert_screen('summary-page');
    assert_and_click('summary-install');
    assert_and_click('summary-confirm-install');
    assert_and_click('all-done-restart', timeout => 3600, mousehide => 1);
    assert_and_click('all-done-done');
}

1;
