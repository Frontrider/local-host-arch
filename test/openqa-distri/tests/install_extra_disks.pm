use Mojo::Base 'basetest';
use testapi;
use LocalHostInstall 'install_system';

sub run {
    my @plan = map { get_required_var($_) }
        qw(EXTRA_DISKS EXTRA_BACKUP EXTRA_BACKUP_FS EXTRA_RAID);
    install_system(@plan, get_var('WEBDAV_TEST_FOLDER'));
}

sub test_flags {
    return {fatal => 1};
}

1;
