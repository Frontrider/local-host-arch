/* Boot/system disk and swap selection for Calamares.
 *
 * This page replaces the built-in partitioning GUI. It only chooses:
 *   - the whole disk that will hold the ESP/root/swap layout, and
 *   - whether to create no swap, a small swap partition (default) or a
 *     hibernation-sized swap partition.
 *
 * Nothing is written here. The local-host-setup-storage job runs FAI's
 * setup-storage after the Summary page has been accepted, so the disk is not
 * touched while the user is still navigating.
 *
 * The writable device list is generated at boot by local-host-data-devices.py
 * into calamares-data-devices.js (the installDisks array).
 */

import io.calamares.core 1.0

import QtQuick 2.15
import QtQuick.Controls 2.15

import "calamares-data-devices.js" as DeviceList

Item {
    id: page
    width: parent.width
    height: parent.height

    property var rows: []
    property string selectedDisk: ""
    property string rootFs: "btrfs"
    property string swapChoice: "small"

    function readGlobal(name, fallback) {
        var value = Global.value(name)
        if (value === undefined || value === null || ("" + value) === "") {
            return fallback
        }
        return "" + value
    }

    function hasDisk(path) {
        if (!path) {
            return false
        }
        for (var i = 0; i < rows.length; i++) {
            if (rows[i].path === path) {
                return true
            }
        }
        return false
    }

    function refresh() {
        rows = DeviceList.installDisks || []
        selectedDisk = readGlobal("localHostInstallDisk", "")
        rootFs = readGlobal("localHostFilesystem", "btrfs")
        if (rootFs !== "btrfs" && rootFs !== "ext4"
                && rootFs !== "f2fs" && rootFs !== "xfs") {
            rootFs = "btrfs"
        }
        swapChoice = readGlobal("localHostSwapChoice", "small")
        if (swapChoice !== "none" && swapChoice !== "small"
                && swapChoice !== "suspend") {
            swapChoice = "small"
        }
        if (!hasDisk(selectedDisk)) {
            selectedDisk = ""
        }
        if (!selectedDisk && rows.length > 0) {
            selectedDisk = rows[0].path
        }
        rootFsBox.currentIndex = (rootFs === "ext4") ? 1
            : (rootFs === "f2fs") ? 2 : (rootFs === "xfs") ? 3 : 0
        swapBox.currentIndex = (swapChoice === "none") ? 0
            : (swapChoice === "suspend") ? 2 : 1
        sync()
    }

    function swapLabel() {
        if (swapChoice === "none") {
            return qsTrId("lp_swap_none")
        }
        if (swapChoice === "suspend") {
            return qsTrId("lp_swap_suspend")
        }
        return qsTrId("lp_swap_small")
    }

    function summaryDisk(withPath) {
        for (var i = 0; i < rows.length; i++) {
            if (rows[i].path === selectedDisk) {
                return diskTitle(rows[i], withPath)
            }
        }
        return selectedDisk
    }

    function sync() {
        Global.insert("localHostInstallDisk", selectedDisk)
        Global.insert("localHostFilesystem", rootFs)
        Global.insert("localHostSwapChoice", swapChoice)
        var settings = rootFs + ", " + swapLabel()
        config.packageChoice = selectedDisk
            ? qsTrId("lp_summary").arg(summaryDisk(false)).arg(settings).arg(selectedDisk)
            : qsTrId("lp_summary_none")
    }

    function setRootFs(index) {
        rootFs = (index === 1) ? "ext4"
            : (index === 2) ? "f2fs" : (index === 3) ? "xfs" : "btrfs"
        sync()
    }

    function setSwap(index) {
        swapChoice = (index === 0) ? "none" : (index === 2) ? "suspend" : "small"
        sync()
    }

    function selectDisk(path) {
        selectedDisk = path
        sync()
    }

    function diskTitle(entry, withPath) {
        var parts = []
        var brand = ""
        if (entry.vendor && entry.model) {
            brand = entry.vendor + " " + entry.model
        } else if (entry.model) {
            brand = entry.model
        } else if (entry.vendor) {
            brand = entry.vendor
        } else if (entry.tran) {
            brand = entry.tran
        }
        if (brand) {
            parts.push(brand)
        }
        if (entry.label) {
            parts.push(entry.label)
        }
        if (entry.size) {
            parts.push(entry.size)
        }
        if (withPath !== false && entry.path) {
            parts.push(entry.path)
        }
        return parts.join(" • ")
    }

    function diskState(entry) {
        if (entry.fs) {
            return qsTrId("lp_disk_contains").arg(entry.fs)
        }
        if (entry.partitioned) {
            return qsTrId("lp_disk_partitioned")
        }
        return qsTrId("lp_disk_blank")
    }

    Component.onCompleted: refresh()

    function onActivate() {
        refresh()
    }

    function onLeave() {
        sync()
    }

    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.height
        clip: true

        Column {
            id: content
            x: 20
            y: 20
            width: page.width - 40
            spacing: 8

            Text {
                width: parent.width
                text: qsTrId("lp_title")
                font.pointSize: 14
                font.bold: true
            }

            Text {
                width: parent.width
                text: qsTrId("lp_description")
                wrapMode: Text.WordWrap
                color: "#a33333"
            }

            Text {
                width: parent.width
                text: qsTrId("lp_title")
                font.bold: true
                topPadding: 4
            }

            Repeater {
                model: page.rows

                delegate: Column {
                    width: parent.width
                    spacing: 0

                    RadioButton {
                        width: parent.width
                        text: page.diskTitle(modelData)
                        checked: page.selectedDisk === modelData.path
                        ButtonGroup.group: diskGroup
                        onClicked: page.selectDisk(modelData.path)
                    }
                    Text {
                        x: 28
                        width: parent.width - 28
                        text: page.diskState(modelData)
                        wrapMode: Text.WordWrap
                        font.pointSize: 9
                    }
                }
            }

            Text {
                width: parent.width
                visible: page.rows.length === 0
                text: qsTrId("lp_no_disks")
                wrapMode: Text.WordWrap
                color: "#a33333"
            }

            Text {
                width: parent.width
                text: qsTrId("lp_rootfs_title")
                font.bold: true
                topPadding: 10
            }

            ComboBox {
                id: rootFsBox
                width: Math.min(560, parent.width)
                model: [
                    qsTrId("lp_rootfs_btrfs"),
                    qsTrId("lp_rootfs_ext4"),
                    qsTrId("lp_rootfs_f2fs"),
                    qsTrId("lp_rootfs_xfs")
                ]
                onActivated: page.setRootFs(index)
            }

            Text {
                width: parent.width
                text: qsTrId("lp_swap_title")
                font.bold: true
                topPadding: 10
            }

            ComboBox {
                id: swapBox
                width: Math.min(420, parent.width)
                model: [
                    qsTrId("lp_swap_none_option"),
                    qsTrId("lp_swap_small_option"),
                    qsTrId("lp_swap_suspend_option")
                ]
                onActivated: page.setSwap(index)
            }

            Text {
                width: parent.width
                text: qsTrId("lp_swap_help")
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }

            Text {
                width: parent.width
                text: page.rootFs === "btrfs"
                    ? qsTrId("lp_root_help")
                    : qsTrId("lp_root_help_other").arg(page.rootFs)
                wrapMode: Text.WordWrap
                font.pointSize: 9
                topPadding: 8
            }
        }
    }

    ButtonGroup { id: diskGroup }
}
