#!/usr/bin/env python3
"""No-op compatibility module for Calamares' partition dependency.

The real partitioning is performed by local-host-setup-storage using FAI
setup-storage. The stock bootloader module declares

    requiredModules: [ "partition" ]

and refuses to load unless a module named "partition" has already been loaded
in the sequence. This job satisfies that ordering requirement and does
nothing else.
"""


def pretty_name():
    return "Partition information"


def run():
    return None
