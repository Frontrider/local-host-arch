use Mojo::Base 'basetest';
use testapi;
use LocalHostStorage 'verify_storage';

sub run {
    verify_storage(map { get_required_var($_) }
        qw(EXTRA_DISKS EXTRA_BACKUP EXTRA_BACKUP_FS EXTRA_RAID));
}

sub test_flags {
    return {fatal => 1};
}

1;
