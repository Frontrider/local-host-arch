use Mojo::Base 'basetest';
use testapi;
use LocalHostGuest 'run_guest_check';

sub run {
    run_guest_check('verify-webdav-backup.sh', 'WebDAV backup and restore', 240,
        get_required_var('WEBDAV_TEST_FOLDER'));
}

sub test_flags {
    return {fatal => 1};
}

1;
