use Mojo::Base 'basetest';
use LocalHostGuest 'run_guest_check';

sub run {
    run_guest_check('verify-midnight-backup.sh', 'Midnight backup', 240);
}

sub test_flags {
    return {fatal => 1};
}

1;
