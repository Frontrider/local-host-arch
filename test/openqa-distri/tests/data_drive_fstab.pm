use Mojo::Base 'basetest';
use LocalHostStorage 'verify_storage';

sub run {
    verify_storage(1, 0, '', '');
}

sub test_flags {
    return {fatal => 1};
}

1;
