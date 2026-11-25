# Test distribution for the local-host Manjaro live ISO.
#
# The test modules are normal Perl modules, so each one has its own package and
# its own run()/test_flags(). main.pm is the Perl scheduler, as required by
# os-autoinst. Each module asserts one screen before touching it, so a layout
# change fails at the step it broke instead of somewhere later.
use strict;
use warnings;
use testapi;
use autotest;

# Extra-disk install plans, keyed by the openQA test suite name. The installer
# uses the first disk for the system and the remaining disks for data, RAID
# and/or backup storage. The variables are read by install_extra_disks.pm and
# verify_extra_disks.pm.
#
#   disks      number of extra disks selected on the Storage drives page
#   backup     whether one of them is assigned as the backup disk
#   backup_fs  filesystem for the backup disk
#   raid       data RAID level (RAID1 is the installer default)
my %extra_suites = (
    'install-data-drive' => {
        disks => 1, backup => 0, backup_fs => '', raid => '',
    },
    'install-backup-only' => {
        disks => 1, backup => 1, backup_fs => 'btrfs', raid => '',
    },
    'install-webdav-backup' => {
        disks => 1, backup => 1, backup_fs => 'btrfs', raid => '',
    },
    'install-backup-drive' => {
        disks => 2, backup => 1, backup_fs => 'btrfs', raid => '',
    },
    'install-data-backup-f2fs' => {
        disks => 2, backup => 1, backup_fs => 'f2fs', raid => '',
    },
    'install-raid1' => {
        disks => 2, backup => 0, backup_fs => '', raid => 'RAID1',
    },
    'install-raid0' => {
        disks => 2, backup => 0, backup_fs => '', raid => 'RAID0',
    },
    'install-raid1-backup' => {
        disks => 3, backup => 1, backup_fs => 'btrfs', raid => 'RAID1',
    },
    'install-raid1-backup-f2fs' => {
        disks => 3, backup => 1, backup_fs => 'f2fs', raid => 'RAID1',
    },
);

autotest::loadtest('tests/boot_to_desktop.pm');

my $suite = get_var('TEST') // 'install';
if (my $plan = $extra_suites{$suite}) {
    set_var('EXTRA_DISKS', $plan->{disks});
    set_var('EXTRA_BACKUP', $plan->{backup});
    set_var('EXTRA_BACKUP_FS', $plan->{backup_fs});
    set_var('EXTRA_RAID', $plan->{raid});
    if ($suite eq 'install-webdav-backup') {
        # rclone sync can delete at the destination. Never reuse a remote
        # folder, even when retrying the same scenario.
        my $suffix = hashed_string(join(':', get_required_var('NAME'), time, $$, rand()), 16);
        set_var('WEBDAV_TEST_FOLDER', "openqa-job-$suffix");
    }
    autotest::loadtest('tests/install_extra_disks.pm', name => "install_$suite");
    autotest::loadtest('tests/verify_extra_disks.pm', name => "verify_$suite");
    autotest::loadtest('tests/verify_midnight_backup.pm') if $suite eq 'install-backup-only';
    autotest::loadtest('tests/verify_webdav_backup.pm') if $suite eq 'install-webdav-backup';
}
elsif ($suite eq 'install') {
    autotest::loadtest('tests/install_defaults.pm');
    autotest::loadtest('tests/installed_welcome.pm');
}
else {
    die "unknown test suite: $suite\n";
}

1;
