use Mojo::Base 'basetest';
use LocalHostInstall 'install_system';

# Standalone equivalent of the install-data-drive plan in main.pm.
sub run {
    install_system(1, 0, '', '');
}

sub test_flags {
    return {fatal => 1};
}

1;
