/* Data storage confirmation page for Calamares.
 *
 * The previous page stores the selected devices in Global Storage under
 * packagechooser_data. Any one of the selected devices can be assigned to the
 * backup role; the remaining devices are the main data disks. The main data
 * filesystem and the backup filesystem are chosen independently.
 *
 * The friendly summary is what Calamares shows on the Summary page, e.g.
 *   "btrfs for user data on RAID1 (ATA QEMU HARDDISK • DATA1 • 64GiB • /dev/vdb) • ..."
 * Each selected entry is stored as "label|path", so the make/model and label
 * come first and the /dev path is last.
 * The install helper reads the data filesystem, RAID level, backup filesystem
 * and backup device from the dataPlan* Global Storage keys. The summary text
 * is display-only, so it can use plain language and translated strings.
 */

import io.calamares.core 1.0
import io.calamares.ui 1.0

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.3

import "calamares-data-devices.js" as DeviceList

Item {
    id: page
    width: parent.width
    height: parent.height

    property string selectedDevices: ""
    property int lastDeviceCount: -1
    property bool updatingRaid: false
    property bool applying: false
    property bool ready: false
    property bool keepMode: false
    property bool asIsMode: false

    // The same radio-row design as the data-device page is used here instead
    // of combo boxes. backupDeviceIndex 0 means "no backup disk".
    property int backupDeviceIndex: 0
    property int backupFsIndex: 0
    readonly property var backupFsOptions: [ "btrfs", "f2fs", "ext4" ]
    property var raidOptions: []
    property string raidChoice: ""

    function readDevices() {
        var raw = Global.value("packagechooser_data")
        if (raw === undefined || raw === null) {
            selectedDevices = ""
        } else {
            selectedDevices = "" + raw
        }
    }

    readonly property int deviceCount: {
        var s = selectedDevices
        if (!s) {
            return 0
        }
        var parts = s.split(",")
        var n = 0
        for (var i = 0; i < parts.length; i++) {
            if (parts[i].trim().length > 0) {
                n++
            }
        }
        return n
    }

    readonly property var backupOptions: {
        var list = [ qsTrId("dc_no_backup") ]
        var parts = selectedDevices.split(",")
        for (var i = 0; i < parts.length; i++) {
            var d = parts[i].trim()
            if (d) {
                list.push(displayDevice(d))
            }
        }
        return list
    }

    function deviceAt(index) {
        var parts = selectedDevices.split(",")
        for (var i = 0; i < parts.length; i++) {
            var d = parts[i].trim()
            if (!d) {
                continue
            }
            if (index === 0) {
                return d
            }
            index--
        }
        return ""
    }

    function entryPath(entry) {
        var s = "" + entry
        return s.split("|").pop().trim()
    }

    function entryLabel(entry) {
        var s = "" + entry
        var parts = s.split("|")
        if (parts.length > 1) {
            return parts.slice(0, -1).join("|").trim()
        }
        return ""
    }

    function displayDevice(entry) {
        var path = entryPath(entry)
        var label = entryLabel(entry)
        return label ? label + " • " + path : path
    }

    function displayDevices(list) {
        var out = []
        for (var i = 0; i < list.length; i++) {
            out.push(displayDevice(list[i]))
        }
        return out.join(", ")
    }

    function selectedEntries() {
        var list = []
        for (var i = 0; i < deviceCount; i++) {
            list.push(deviceAt(i))
        }
        return list
    }

    function deviceIndex(dev) {
        if (!dev) {
            return 0
        }
        // Accept a bare path or a "label|path" entry.
        var wanted = ("" + dev).split("|").pop().trim()
        for (var i = 0; i < deviceCount; i++) {
            if (entryPath(deviceAt(i)) === wanted) {
                return i + 1
            }
        }
        return 0
    }

    function backupDevice() {
        if (backupDeviceIndex <= 0 || backupDeviceIndex > deviceCount) {
            return ""
        }
        return deviceAt(backupDeviceIndex - 1)
    }

    function backupWanted() {
        return backupDevice() !== "" && deviceCount >= 1
    }

    function dataDevices() {
        var backup = backupWanted() ? entryPath(backupDevice()) : ""
        var list = []
        for (var i = 0; i < deviceCount; i++) {
            var d = deviceAt(i)
            if (backup && entryPath(d) === backup) {
                continue
            }
            list.push(d)
        }
        return list
    }

    function dataCountForMode() {
        return dataDevices().length
    }

    function deviceEntry(entry) {
        var path = entryPath(entry)
        var list = DeviceList.devices || []
        for (var i = 0; i < list.length; i++) {
            if (list[i].path === path) {
                return list[i]
            }
        }
        return null
    }

    function asIsFs(entry) {
        var value = entry
        if (!value) {
            var data = dataDevices()
            if (data.length !== 1) {
                return ""
            }
            value = data[0]
        }
        var device = deviceEntry(value)
        if (!device) {
            return ""
        }
        var fs = "" + (device.fs || "")
        if (fs === "btrfs" || fs === "ext4" || fs === "f2fs" || fs === "xfs") {
            return fs
        }
        return ""
    }

    function asIsAvailable() {
        return dataCountForMode() === 1 && asIsFs(dataDevices()[0]) !== ""
    }

    function raidOptionsFor(count) {
        if (count >= 4) {
            return [ "RAID10", "RAID1C4", "RAID1C3", "RAID1", "RAID0" ]
        }
        if (count === 3) {
            return [ "RAID1C3", "RAID1", "RAID0" ]
        }
        if (count === 2) {
            return [ "RAID1", "RAID0" ]
        }
        return []
    }

    function levelFromChoice() {
        var c = ("" + (Global.value("dataPlanRaid") || "")).toUpperCase()
        var levels = [ "RAID10", "RAID1C4", "RAID1C3", "RAID1", "RAID0" ]
        return levels.indexOf(c) >= 0 ? c : ""
    }

    function backupFsLabel(value) {
        if (value === "f2fs") {
            return qsTrId("dc_fs_f2fs")
        }
        if (value === "ext4") {
            return qsTrId("dc_fs_ext4")
        }
        return qsTrId("dc_fs_btrfs")
    }

    function raidLabel(value) {
        if (value === "RAID10") {
            return qsTrId("dc_raid10")
        }
        if (value === "RAID1C4") {
            return qsTrId("dc_raid1c4")
        }
        if (value === "RAID1C3") {
            return qsTrId("dc_raid1c3")
        }
        if (value === "RAID1") {
            return qsTrId("dc_raid1")
        }
        if (value === "RAID0") {
            return qsTrId("dc_raid0")
        }
        return value
    }

    function raidDetail(value) {
        if (value === "RAID10") {
            return qsTrId("dc_raid10_detail")
        }
        if (value === "RAID1C4") {
            return qsTrId("dc_raid1c4_detail")
        }
        if (value === "RAID1C3") {
            return qsTrId("dc_raid1c3_detail")
        }
        if (value === "RAID1") {
            return qsTrId("dc_raid1_detail")
        }
        if (value === "RAID0") {
            return qsTrId("dc_raid0_detail")
        }
        return ""
    }

    function updateRaidOptions() {
        var opts = (mainBtrfsRadio.checked && !keepMode)
            ? raidOptionsFor(dataCountForMode()) : []
        var wanted = levelFromChoice()
        var index = opts.indexOf(wanted)
        if (index < 0) {
            index = 0        // highest available
        }

        updatingRaid = true
        raidOptions = opts
        raidChoice = opts.length ? opts[index] : ""
        updatingRaid = false
        updateSummary()
    }

    function updatePlanKeys() {
        var data = dataDevices()
        var paths = []
        for (var i = 0; i < data.length; i++) {
            paths.push(entryPath(data[i]))
        }
        var asis = asIsMode && asIsAvailable()
        var fs = asis ? asIsFs(data[0]) : (keepMode ? "" : (mainF2fsRadio.checked ? "f2fs"
            : (mainExt4Radio.checked ? "ext4" : "btrfs")))
        var raid = (!asis && fs === "btrfs" && data.length >= 2) ? raidChoice : ""
        Global.insert("dataPlanDevices", keepMode ? "" : paths.join(","))
        Global.insert("dataPlanBackup", backupWanted() ? entryPath(backupDevice()) : "")
        Global.insert("dataPlanFs", fs)
        Global.insert("dataPlanBackupFs", backupFsOptions[backupFsIndex] || "btrfs")
        Global.insert("dataPlanRaid", raid)
        Global.insert("dataPlanKeep", keepMode ? "true" : "false")
        Global.insert("dataPlanAsIs", asis ? "true" : "false")
    }

    function updateSummary() {
        updatePlanKeys()
        var backupDev = backupWanted() ? backupDevice() : ""
        var data = dataDevices()
        var backupFs = backupFsOptions[backupFsIndex] || "btrfs"

        var main
        if (keepMode || !data.length) {
            main = qsTrId("dc_summary_keep")
        } else if (asIsMode && asIsAvailable()) {
            main = qsTrId("dc_summary_asis")
                .arg(asIsFs(data[0]))
                .arg(displayDevice(data[0]))
        } else if (mainF2fsRadio.checked) {
            main = qsTrId("dc_summary_f2fs").arg(displayDevice(data[0]))
        } else if (mainExt4Radio.checked) {
            main = qsTrId("dc_summary_ext4").arg(displayDevice(data[0]))
        } else if (raidChoice && data.length >= 2) {
            main = qsTrId("dc_summary_btrfs_raid")
                .arg(raidChoice)
                .arg(displayDevices(data))
        } else {
            main = qsTrId("dc_summary_btrfs").arg(displayDevices(data))
        }

        if (backupDev) {
            main += " • " + qsTrId("dc_summary_backup")
                .arg(backupFs)
                .arg(displayDevice(backupDev))
        }
        config.packageChoice = main
    }

    function applyState() {
        if (applying) {
            return
        }
        applying = true
        keepMode = keepRadio.checked
        asIsMode = asIsRadio.checked

        if (deviceCount < 1 && backupDeviceIndex > 0) {
            backupDeviceIndex = 0
        }
        if (backupDeviceIndex >= backupOptions.length) {
            backupDeviceIndex = 0
        }

        // A backup drive can be used while user data stays on the system
        // drive. When the only selected drive is assigned to the backup role,
        // there is no data drive left, so select the keep option explicitly.
        if (!keepMode && backupWanted() && dataCountForMode() === 0) {
            keepRadio.checked = true
            keepMode = true
        }

        if (!keepMode
                && !mainBtrfsRadio.checked && !mainF2fsRadio.checked
                && !mainExt4Radio.checked && !asIsRadio.checked) {
            if (dataCountForMode() > 0) {
                mainBtrfsRadio.checked = true
            } else {
                keepRadio.checked = true
            }
        }

        if (asIsRadio.checked && !asIsAvailable()) {
            if (dataCountForMode() > 0) {
                mainBtrfsRadio.checked = true
            } else {
                keepRadio.checked = true
            }
            asIsMode = false
        }

        if ((mainF2fsRadio.checked || mainExt4Radio.checked)
                && dataCountForMode() !== 1) {
            mainBtrfsRadio.checked = true
        }

        applying = false
        updateRaidOptions()
        updateSummary()
    }

    function syncFromChoice() {
        // The visible summary and the stored plan are separate. Read the
        // plan directly so the text can stay friendly and translatable.
        var fs = "" + (Global.value("dataPlanFs") || "")
        var keep = "" + (Global.value("dataPlanKeep") || "false")
        var asis = "" + (Global.value("dataPlanAsIs") || "false")
        var backupDev = "" + (Global.value("dataPlanBackup") || "")
        var backupFs = "" + (Global.value("dataPlanBackupFs") || "btrfs")

        applying = true
        backupDeviceIndex = deviceIndex(backupDev)
        backupFsIndex = (backupFs === "f2fs") ? 1
            : (backupFs === "ext4") ? 2 : 0

        if (asis === "true") {
            asIsRadio.checked = true
        } else if (keep === "true") {
            if (deviceCount > 0 && lastDeviceCount < 1) {
                mainBtrfsRadio.checked = true
            } else {
                keepRadio.checked = true
            }
        } else if (fs === "f2fs") {
            mainF2fsRadio.checked = true
        } else if (fs === "ext4") {
            mainExt4Radio.checked = true
        } else if (fs === "btrfs") {
            mainBtrfsRadio.checked = true
        } else if (deviceCount > 0) {
            mainBtrfsRadio.checked = true
        } else {
            keepRadio.checked = true
        }
        applying = false

        lastDeviceCount = deviceCount
        applyState()
    }

    Component.onCompleted: {
        // Suppress model/currentIndex callbacks while the device list and the
        // saved choice are being loaded.
        applying = true
        readDevices()
        syncFromChoice()
        ready = true
    }

    function onActivate() {
        applying = true
        readDevices()
        syncFromChoice()
        ready = true
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
                text: qsTrId("dc_title")
                font.pointSize: 14
                font.bold: true
            }

            Text {
                width: parent.width
                text: qsTrId("dc_selected_devices") + (page.deviceCount ? page.displayDevices(page.selectedEntries()) : qsTrId("dc_none"))
                wrapMode: Text.WordWrap
            }

            Text {
                width: parent.width
                text: qsTrId("dc_erase_warning")
                wrapMode: Text.WordWrap
                color: "#a33333"
            }

            Text {
                width: parent.width
                visible: deviceCount >= 1
                text: qsTrId("dc_backup_disk")
                font.bold: true
                topPadding: 4
            }

            Column {
                width: parent.width
                visible: deviceCount >= 1

                Repeater {
                    model: page.backupOptions

                    delegate: RadioButton {
                        width: parent.width
                        text: modelData
                        checked: page.backupDeviceIndex === index
                        ButtonGroup.group: backupDeviceGroup
                        onClicked: {
                            page.backupDeviceIndex = index
                            page.applyState()
                        }
                    }
                }
            }
            Text {
                x: 28
                width: parent.width - 28
                visible: deviceCount >= 1
                text: qsTrId("dc_backup_help")
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }

            Text {
                width: parent.width
                visible: page.backupWanted()
                text: qsTrId("dc_main_data") + page.displayDevices(page.dataDevices())
                    + qsTrId("dc_backup_disk_prefix") + page.displayDevice(page.backupDevice())
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }

            Text {
                width: parent.width
                visible: page.backupWanted()
                text: qsTrId("dc_backup_fs")
                font.bold: true
                topPadding: 4
            }

            Column {
                width: parent.width
                visible: page.backupWanted()

                Repeater {
                    model: page.backupFsOptions

                    delegate: RadioButton {
                        width: parent.width
                        text: page.backupFsLabel(modelData)
                        checked: page.backupFsIndex === index
                        ButtonGroup.group: backupFsGroup
                        onClicked: {
                            page.backupFsIndex = index
                            page.updateSummary()
                        }
                    }
                }
            }
            Text {
                x: 28
                width: parent.width - 28
                visible: page.backupWanted()
                text: qsTrId("dc_backup_fs_help")
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }

            Text {
                width: parent.width
                text: qsTrId("dc_main_data_title")
                font.bold: true
                topPadding: 4
            }

            RadioButton {
                id: mainBtrfsRadio
                width: parent.width
                text: qsTrId("dc_btrfs")
                enabled: deviceCount > 0
                onCheckedChanged: {
                    if (page.ready && checked) {
                        page.applyState()
                    }
                }
            }
            Text {
                x: 28
                width: parent.width - 28
                text: qsTrId("dc_btrfs_help")
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }

            Text {
                width: parent.width
                visible: mainBtrfsRadio.checked && page.dataCountForMode() >= 2
                text: qsTrId("dc_raid")
                font.bold: true
                topPadding: 4
            }

            Column {
                width: parent.width
                visible: mainBtrfsRadio.checked && page.dataCountForMode() >= 2

                Repeater {
                    model: page.raidOptions

                    delegate: Column {
                        width: parent.width
                        spacing: 0

                        RadioButton {
                            width: parent.width
                            text: page.raidLabel(modelData)
                            checked: page.raidChoice === modelData
                            ButtonGroup.group: raidGroup
                            onClicked: {
                                page.raidChoice = modelData
                                page.updateSummary()
                            }
                        }
                        Text {
                            x: 28
                            width: parent.width - 28
                            text: page.raidDetail(modelData)
                            wrapMode: Text.WordWrap
                            font.pointSize: 9
                            bottomPadding: 4
                        }
                    }
                }
            }
            Text {
                x: 28
                width: parent.width - 28
                visible: mainBtrfsRadio.checked && page.dataCountForMode() >= 2
                text: qsTrId("dc_raid_help")
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }

            RadioButton {
                id: mainF2fsRadio
                width: parent.width
                text: qsTrId("dc_f2fs")
                enabled: deviceCount > 0 && page.dataCountForMode() === 1
                onCheckedChanged: {
                    if (page.ready && checked) {
                        page.applyState()
                    }
                }
            }
            Text {
                x: 28
                width: parent.width - 28
                text: qsTrId("dc_f2fs_help")
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }

            RadioButton {
                id: mainExt4Radio
                width: parent.width
                text: qsTrId("dc_ext4")
                enabled: deviceCount > 0 && page.dataCountForMode() === 1
                onCheckedChanged: {
                    if (page.ready && checked) {
                        page.applyState()
                    }
                }
            }
            Text {
                x: 28
                width: parent.width - 28
                text: qsTrId("dc_ext4_help")
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }

            RadioButton {
                id: asIsRadio
                width: parent.width
                text: qsTrId("dc_asis")
                enabled: page.asIsAvailable()
                onCheckedChanged: {
                    if (page.ready && checked) {
                        page.applyState()
                    }
                }
            }
            Text {
                x: 28
                width: parent.width - 28
                text: qsTrId("dc_asis_help")
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }

            RadioButton {
                id: keepRadio
                width: parent.width
                text: qsTrId("dc_keep")
                onCheckedChanged: {
                    if (page.ready && checked) {
                        page.applyState()
                    }
                }
            }
            Text {
                x: 28
                width: parent.width - 28
                text: qsTrId("dc_keep_help")
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }
        }
    }

    ButtonGroup {
        buttons: [ mainBtrfsRadio, mainF2fsRadio, mainExt4Radio, asIsRadio, keepRadio ]
    }
    ButtonGroup { id: backupDeviceGroup }
    ButtonGroup { id: backupFsGroup }
    ButtonGroup { id: raidGroup }
}
