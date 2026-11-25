use Mojo::Base 'basetest';
use LocalHostStorage 'verify_storage';

sub run {
    verify_storage(2, 1, 'btrfs', '');
}

sub test_flags {
    return {fatal => 1};
}

1;
