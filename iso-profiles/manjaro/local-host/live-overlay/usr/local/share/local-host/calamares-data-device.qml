/* Data storage page for Calamares.
 *
 * The disk inventory is generated at boot by local-host-data-devices.py into
 * calamares-data-devices.js. The installation disk page runs before this one
 * and stores localHostInstallDisk, so this page hides that disk and every
 * partition on it.
 *
 * The inventory contains structured device fields, not display text, so the
 * labels and descriptions below can be translated through qsTrId(). The
 * translation context is the QML file name: calamares-data-device.
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
    property var chosen: ({})

    function isNetworkName(path) {
        var name = ("" + (path || "")).toLowerCase()
        return name.indexOf("nbd") >= 0
            || name.indexOf("rbd") >= 0
            || name.indexOf("drbd") >= 0
    }

    function installDisk() {
        var value = Global.value("localHostInstallDisk")
        if (value === undefined || value === null) {
            return ""
        }
        return "" + value
    }

    function isVisible(entry) {
        if (!entry || entry.id === undefined) {
            return false
        }
        var path = entry.path || ("" + entry.id).split("|")[0]
        if (isNetworkName(path) || isNetworkName(entry.parent)
                || isNetworkName(entry.id)) {
            return false
        }
        var disk = installDisk()
        if (disk && (path === disk || entry.parent === disk)) {
            return false
        }
        return true
    }

    function visibleId(id) {
        for (var i = 0; i < rows.length; i++) {
            if (rows[i].id === id) {
                return true
            }
        }
        return false
    }

    function selectedIds() {
        var out = []
        for (var id in chosen) {
            if (id && chosen[id]) {
                out.push(id)
            }
        }
        return out
    }

    function entryById(id) {
        for (var i = 0; i < rows.length; i++) {
            if (rows[i].id === id) {
                return rows[i]
            }
        }
        return null
    }

    function syncChoice() {
        config.packageChoice = selectedIds().join(",")
    }

    function refresh() {
        var list = []
        var inventory = DeviceList.devices || []
        for (var i = 0; i < inventory.length; i++) {
            if (isVisible(inventory[i])) {
                list.push(inventory[i])
            }
        }
        rows = list

        var selection = {}
        var current = "" + config.packageChoice
        if (current) {
            var parts = current.split(",")
            for (var j = 0; j < parts.length; j++) {
                var id = parts[j].trim()
                if (id) {
                    selection[id] = true
                }
            }
        }
        for (var selected in selection) {
            if (!visibleId(selected)) {
                delete selection[selected]
            }
        }
        if (Object.keys(selection).length === 0) {
            selection[""] = true
        }
        chosen = selection
        syncChoice()
    }

    function toggle(id, checked) {
        var selection = {}
        if (id === "") {
            if (checked) {
                selection[""] = true
            }
        } else {
            for (var existing in chosen) {
                if (existing && chosen[existing]) {
                    selection[existing] = true
                }
            }
            if (checked) {
                selection[id] = true
            } else {
                delete selection[id]
            }
        }
        if (Object.keys(selection).length === 0) {
            selection[""] = true
        }
        chosen = selection
        syncChoice()
    }

    /* Visible text for a device. The fields come from the generated inventory;
     * only these qsTrId() strings need translating. */
    function brandText(entry) {
        if (entry.vendor && entry.model) {
            return entry.vendor + " " + entry.model
        }
        if (entry.model) {
            return entry.model
        }
        if (entry.vendor) {
            return entry.vendor
        }
        if (entry.tran) {
            return entry.tran
        }
        return ""
    }

    function entryTitle(entry) {
        if (!entry || entry.kind === "none") {
            return qsTrId("dd_none")
        }
        var parts = []
        var brand = brandText(entry)
        if (brand) {
            parts.push(brand)
        }
        if (entry.label) {
            parts.push(entry.label)
        } else if (entry.fs) {
            parts.push(entry.fs)
        } else if (entry.kind === "partition") {
            parts.push(qsTrId("dd_state_blank_partition"))
        } else if (entry.partitioned) {
            parts.push(qsTrId("dd_state_partitioned"))
        } else {
            parts.push(qsTrId("dd_state_blank"))
        }
        if (entry.size) {
            parts.push(entry.size)
        }
        // The path is only needed when there is no filesystem label.
        if (!entry.label && entry.path) {
            parts.push(entry.path)
        }
        return parts.join(" • ")
    }

    function listHint() {
        var hasDisk = false
        for (var i = 0; i < rows.length; i++) {
            if (rows[i].kind === "disk") {
                hasDisk = true
                break
            }
        }
        var hint = hasDisk
            ? qsTrId("dd_hint_disk")
            : qsTrId("dd_hint_formatted_partition")
        if (hasDisk) {
            hint += " • " + qsTrId("dd_hint_confirm")
        }
        return hint + " • " + qsTrId("dd_erased")
    }

    function entryDescription(entry) {
        if (!entry || entry.kind === "none") {
            return rows.length > 1 ? qsTrId("dd_none_exclusive") : ""
        }

        if (entry.mountedAt) {
            return qsTrId("dd_mounted_at").arg(entry.mountedAt)
        }
        return ""
    }

    Component.onCompleted: refresh()

    function onActivate() {
        refresh()
    }

    function onLeave() {
        syncChoice()
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
                text: qsTrId("dd_title")
                font.pointSize: 14
                font.bold: true
            }

            Text {
                width: parent.width
                text: qsTrId("dd_subtitle")
                wrapMode: Text.WordWrap
                color: "#a33333"
            }

            Text {
                width: parent.width
                visible: page.rows.length > 1
                text: page.listHint()
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }

            Repeater {
                model: page.rows

                delegate: Column {
                    width: parent.width
                    spacing: 0

                    CheckBox {
                        width: parent.width
                        text: page.entryTitle(modelData)
                        checked: page.chosen[modelData.id] === true
                        // Use clicked, not checkedChanged: changing another
                        // checkbox updates this binding and must not be
                        // mistaken for a user click.
                        onClicked: page.toggle(modelData.id, checked)
                    }
                    Text {
                        x: 28
                        width: parent.width - 28
                        visible: text !== ""
                        text: page.entryDescription(modelData)
                        wrapMode: Text.WordWrap
                        font.pointSize: 9
                    }
                }
            }

            Text {
                width: parent.width
                visible: page.rows.length <= 1
                text: qsTrId("dd_no_data_disk")
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }
        }
    }
}
