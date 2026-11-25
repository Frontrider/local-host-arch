use Mojo::Base 'basetest';
use LocalHostInstall 'install_system';

sub run {
    install_system(0, 0, '', '');
}

sub test_flags {
    return {fatal => 1};
}

1;
