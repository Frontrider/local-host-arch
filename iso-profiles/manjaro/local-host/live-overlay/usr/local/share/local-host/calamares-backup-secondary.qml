/* Second (off-site) backup configuration page for Calamares.
 *
 * The main backup keeps a restic repository for all of /data on the backup
 * drive. This page configures a second, independent restic repository that
 * only contains /data/data/backed-up, stored either on the backup drive
 * or under /data/backup. The repository is mirrored to a remote rclone
 * target (Google Drive, OneDrive, WebDAV or FTP) after each backup.
 *
 * The page only writes Global Storage keys. The
 * local-host-setup-secondary-backup job creates the password, rclone config
 * and systemd units after the Summary page has been accepted.
 */

import io.calamares.core 1.0
import io.calamares.ui 1.0

import QtQuick 2.15
import QtQuick.Controls 2.15

Item {
    id: page
    width: parent.width
    height: parent.height

    property bool ready: false
    property bool updating: false
    property string location: "data"
    property string provider: "none"

    readonly property var providerOptions: [ "none", "drive", "onedrive", "webdav", "ftp" ]
    property bool hasBackupDrive: false

    function readGlobal(name, fallback) {
        var value = Global.value(name)
        if (value === undefined || value === null || ("" + value) === "") {
            return fallback
        }
        return "" + value
    }

    function providerLabel(value) {
        if (value === "drive") {
            return qsTrId("sb_provider_drive")
        }
        if (value === "onedrive") {
            return qsTrId("sb_provider_onedrive")
        }
        if (value === "webdav") {
            return qsTrId("sb_provider_webdav")
        }
        if (value === "ftp") {
            return qsTrId("sb_provider_ftp")
        }
        return qsTrId("sb_provider_none")
    }

    function providerIndex(value) {
        var index = providerOptions.indexOf(value)
        return index < 0 ? 0 : index
    }

    function providerIncomplete() {
        if (!enabledBox.checked || provider === "none") {
            return false
        }
        if (provider === "drive") {
            return googleToken.text.trim() === ""
        }
        if (provider === "onedrive") {
            return oneDriveToken.text.trim() === ""
        }
        if (provider === "webdav") {
            return webdavUrl.text.trim() === ""
        }
        if (provider === "ftp") {
            return ftpHost.text.trim() === ""
        }
        return false
    }

    function summaryText() {
        if (!enabledBox.checked) {
            return qsTrId("sb_summary_off")
        }
        var where = location === "drive"
            ? qsTrId("sb_summary_drive")
            : qsTrId("sb_summary_data")
        var remote = provider === "none"
            ? qsTrId("sb_summary_local_only")
            : qsTrId("sb_summary_remote")
                .arg(providerLabel(provider))
                .arg(remotePath.text.trim() || "local-host-backup")
        var text = qsTrId("sb_summary").arg(where).arg(remote)
        if (providerIncomplete()) {
            text += " — " + qsTrId("sb_incomplete")
        }
        return text
    }

    function sync() {
        if (updating || !ready) {
            return
        }
        if (location === "drive" && !hasBackupDrive) {
            location = "data"
            driveRadio.checked = false
            dataRadio.checked = true
        }

        var enabled = enabledBox.checked
        Global.insert("secondaryBackupEnabled", enabled ? "true" : "false")
        Global.insert("secondaryBackupLocation", location)
        Global.insert("secondaryBackupProvider", enabled ? provider : "none")
        Global.insert("secondaryBackupRemotePath", remotePath.text.trim())

        Global.insert("secondaryBackupGoogleToken", googleToken.text.trim())
        Global.insert("secondaryBackupGoogleClientId", googleClientId.text.trim())
        Global.insert("secondaryBackupGoogleClientSecret", googleClientSecret.text.trim())
        Global.insert("secondaryBackupGoogleRootFolderId", googleRootFolderId.text.trim())

        Global.insert("secondaryBackupOneDriveToken", oneDriveToken.text.trim())
        Global.insert("secondaryBackupOneDriveClientId", oneDriveClientId.text.trim())
        Global.insert("secondaryBackupOneDriveClientSecret", oneDriveClientSecret.text.trim())
        Global.insert("secondaryBackupOneDriveDriveId", oneDriveDriveId.text.trim())
        Global.insert("secondaryBackupOneDriveDriveType", oneDriveDriveType.text.trim())

        Global.insert("secondaryBackupWebdavUrl", webdavUrl.text.trim())
        Global.insert("secondaryBackupWebdavUser", webdavUser.text)
        Global.insert("secondaryBackupWebdavPass", webdavPass.text)

        Global.insert("secondaryBackupFtpHost", ftpHost.text.trim())
        Global.insert("secondaryBackupFtpPort", ftpPort.text.trim())
        Global.insert("secondaryBackupFtpUser", ftpUser.text)
        Global.insert("secondaryBackupFtpPass", ftpPass.text)
        Global.insert("secondaryBackupFtpTls", ftpTls.checked ? "true" : "false")
        Global.insert("secondaryBackupFtpExplicitTls", ftpExplicitTls.checked ? "true" : "false")

        config.packageChoice = summaryText()
    }

    function load() {
        updating = true
        hasBackupDrive = ("" + (Global.value("dataPlanBackup") || "")).trim() !== ""
        var enabled = readGlobal("secondaryBackupEnabled", "false") === "true"
        enabledBox.checked = enabled

        location = readGlobal("secondaryBackupLocation", hasBackupDrive ? "drive" : "data")
        if (location !== "drive" || !hasBackupDrive) {
            location = "data"
        }
        driveRadio.checked = location === "drive"
        dataRadio.checked = location === "data"

        provider = readGlobal("secondaryBackupProvider", "none")
        if (providerOptions.indexOf(provider) < 0) {
            provider = "none"
        }
        providerBox.currentIndex = providerIndex(provider)

        remotePath.text = readGlobal("secondaryBackupRemotePath",
                                     "local-host-backup")

        googleToken.text = readGlobal("secondaryBackupGoogleToken", "")
        googleClientId.text = readGlobal("secondaryBackupGoogleClientId", "")
        googleClientSecret.text = readGlobal("secondaryBackupGoogleClientSecret", "")
        googleRootFolderId.text = readGlobal("secondaryBackupGoogleRootFolderId", "")

        oneDriveToken.text = readGlobal("secondaryBackupOneDriveToken", "")
        oneDriveClientId.text = readGlobal("secondaryBackupOneDriveClientId", "")
        oneDriveClientSecret.text = readGlobal("secondaryBackupOneDriveClientSecret", "")
        oneDriveDriveId.text = readGlobal("secondaryBackupOneDriveDriveId", "")
        oneDriveDriveType.text = readGlobal("secondaryBackupOneDriveDriveType", "personal")

        webdavUrl.text = readGlobal("secondaryBackupWebdavUrl", "")
        webdavUser.text = readGlobal("secondaryBackupWebdavUser", "")
        webdavPass.text = readGlobal("secondaryBackupWebdavPass", "")

        ftpHost.text = readGlobal("secondaryBackupFtpHost", "")
        ftpPort.text = readGlobal("secondaryBackupFtpPort", "21")
        ftpUser.text = readGlobal("secondaryBackupFtpUser", "")
        ftpPass.text = readGlobal("secondaryBackupFtpPass", "")
        ftpTls.checked = readGlobal("secondaryBackupFtpTls", "false") === "true"
        ftpExplicitTls.checked = readGlobal("secondaryBackupFtpExplicitTls", "false") === "true"

        updating = false
        ready = true
        sync()
    }

    Component.onCompleted: load()

    function onActivate() {
        load()
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
                text: qsTrId("sb_title")
                font.pointSize: 14
                font.bold: true
            }

            Text {
                width: parent.width
                text: qsTrId("sb_intro")
                wrapMode: Text.WordWrap
            }

            CheckBox {
                id: enabledBox
                width: parent.width
                text: qsTrId("sb_enable")
                onCheckedChanged: page.sync()
            }
            Text {
                x: 28
                width: parent.width - 28
                text: qsTrId("sb_enable_help")
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }

            Text {
                width: parent.width
                visible: enabledBox.checked
                text: qsTrId("sb_source")
                wrapMode: Text.WordWrap
                font.bold: true
                topPadding: 4
            }
            Text {
                x: 28
                width: parent.width - 28
                visible: enabledBox.checked
                text: qsTrId("sb_source_help")
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }

            Text {
                width: parent.width
                visible: enabledBox.checked
                text: qsTrId("sb_location_title")
                font.bold: true
                topPadding: 4
            }

            RadioButton {
                id: driveRadio
                width: parent.width
                visible: enabledBox.checked
                enabled: page.hasBackupDrive
                text: qsTrId("sb_location_drive")
                ButtonGroup.group: locationGroup
                onClicked: {
                    page.location = "drive"
                    page.sync()
                }
            }
            Text {
                x: 28
                width: parent.width - 28
                visible: enabledBox.checked
                text: page.hasBackupDrive
                    ? qsTrId("sb_location_drive_help")
                    : qsTrId("sb_location_drive_missing")
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }

            RadioButton {
                id: dataRadio
                width: parent.width
                visible: enabledBox.checked
                text: qsTrId("sb_location_data")
                ButtonGroup.group: locationGroup
                onClicked: {
                    page.location = "data"
                    page.sync()
                }
            }
            Text {
                x: 28
                width: parent.width - 28
                visible: enabledBox.checked
                text: qsTrId("sb_location_data_help")
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }

            Text {
                width: parent.width
                visible: enabledBox.checked
                text: qsTrId("sb_password_note")
                wrapMode: Text.WordWrap
                font.pointSize: 9
                topPadding: 4
            }

            Text {
                width: parent.width
                visible: enabledBox.checked
                text: qsTrId("sb_provider_title")
                font.bold: true
                topPadding: 8
            }
            Text {
                x: 28
                width: parent.width - 28
                visible: enabledBox.checked
                text: qsTrId("sb_provider_help")
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }

            ComboBox {
                id: providerBox
                width: Math.min(420, parent.width)
                visible: enabledBox.checked
                model: [
                    qsTrId("sb_provider_none"),
                    qsTrId("sb_provider_drive"),
                    qsTrId("sb_provider_onedrive"),
                    qsTrId("sb_provider_webdav"),
                    qsTrId("sb_provider_ftp")
                ]
                onActivated: {
                    page.provider = page.providerOptions[index]
                    page.sync()
                }
            }

            Text {
                width: parent.width
                visible: enabledBox.checked && page.provider !== "none"
                text: qsTrId("sb_remote_path")
                font.bold: true
                topPadding: 4
            }
            TextField {
                id: remotePath
                width: Math.min(560, parent.width)
                visible: enabledBox.checked && page.provider !== "none"
                placeholderText: qsTrId("sb_remote_path_placeholder")
                onTextChanged: page.sync()
            }
            Text {
                x: 28
                width: parent.width - 28
                visible: enabledBox.checked && page.provider !== "none"
                text: qsTrId("sb_remote_path_help")
                wrapMode: Text.WordWrap
                font.pointSize: 9
            }

            Column {
                width: parent.width
                spacing: 8
                visible: enabledBox.checked && page.provider === "drive"

                Text {
                    width: parent.width
                    text: qsTrId("sb_google_token")
                    font.bold: true
                    topPadding: 4
                }
                TextArea {
                    id: googleToken
                    width: Math.min(640, parent.width)
                    height: 90
                    wrapMode: TextArea.Wrap
                    placeholderText: qsTrId("sb_token_placeholder")
                    onTextChanged: page.sync()
                }
                Text {
                    x: 28
                    width: parent.width - 28
                    text: qsTrId("sb_google_token_help")
                    wrapMode: Text.WordWrap
                    font.pointSize: 9
                }
                TextField {
                    id: googleClientId
                    width: Math.min(560, parent.width)
                    placeholderText: qsTrId("sb_google_client_id")
                    onTextChanged: page.sync()
                }
                TextField {
                    id: googleClientSecret
                    width: Math.min(560, parent.width)
                    echoMode: TextInput.Password
                    placeholderText: qsTrId("sb_google_client_secret")
                    onTextChanged: page.sync()
                }
                TextField {
                    id: googleRootFolderId
                    width: Math.min(560, parent.width)
                    placeholderText: qsTrId("sb_google_root_folder")
                    onTextChanged: page.sync()
                }
            }

            Column {
                width: parent.width
                spacing: 8
                visible: enabledBox.checked && page.provider === "onedrive"

                Text {
                    width: parent.width
                    text: qsTrId("sb_onedrive_token")
                    font.bold: true
                    topPadding: 4
                }
                TextArea {
                    id: oneDriveToken
                    width: Math.min(640, parent.width)
                    height: 90
                    wrapMode: TextArea.Wrap
                    placeholderText: qsTrId("sb_token_placeholder")
                    onTextChanged: page.sync()
                }
                Text {
                    x: 28
                    width: parent.width - 28
                    text: qsTrId("sb_onedrive_token_help")
                    wrapMode: Text.WordWrap
                    font.pointSize: 9
                }
                TextField {
                    id: oneDriveClientId
                    width: Math.min(560, parent.width)
                    placeholderText: qsTrId("sb_onedrive_client_id")
                    onTextChanged: page.sync()
                }
                TextField {
                    id: oneDriveClientSecret
                    width: Math.min(560, parent.width)
                    echoMode: TextInput.Password
                    placeholderText: qsTrId("sb_onedrive_client_secret")
                    onTextChanged: page.sync()
                }
                TextField {
                    id: oneDriveDriveId
                    width: Math.min(560, parent.width)
                    placeholderText: qsTrId("sb_onedrive_drive_id")
                    onTextChanged: page.sync()
                }
                TextField {
                    id: oneDriveDriveType
                    width: Math.min(560, parent.width)
                    placeholderText: qsTrId("sb_onedrive_drive_type")
                    onTextChanged: page.sync()
                }
            }

            Column {
                width: parent.width
                spacing: 8
                visible: enabledBox.checked && page.provider === "webdav"

                Text {
                    width: parent.width
                    text: qsTrId("sb_webdav_title")
                    font.bold: true
                    topPadding: 4
                }
                TextField {
                    id: webdavUrl
                    width: Math.min(640, parent.width)
                    placeholderText: qsTrId("sb_webdav_url")
                    onTextChanged: page.sync()
                }
                TextField {
                    id: webdavUser
                    width: Math.min(560, parent.width)
                    placeholderText: qsTrId("sb_webdav_user")
                    onTextChanged: page.sync()
                }
                TextField {
                    id: webdavPass
                    width: Math.min(560, parent.width)
                    echoMode: TextInput.Password
                    placeholderText: qsTrId("sb_webdav_pass")
                    onTextChanged: page.sync()
                }
                Text {
                    x: 28
                    width: parent.width - 28
                    text: qsTrId("sb_webdav_help")
                    wrapMode: Text.WordWrap
                    font.pointSize: 9
                }
            }

            Column {
                width: parent.width
                spacing: 8
                visible: enabledBox.checked && page.provider === "ftp"

                Text {
                    width: parent.width
                    text: qsTrId("sb_ftp_title")
                    font.bold: true
                    topPadding: 4
                }
                TextField {
                    id: ftpHost
                    width: Math.min(560, parent.width)
                    placeholderText: qsTrId("sb_ftp_host")
                    onTextChanged: page.sync()
                }
                TextField {
                    id: ftpPort
                    width: Math.min(200, parent.width)
                    placeholderText: qsTrId("sb_ftp_port")
                    inputMethodHints: Qt.ImhDigitsOnly
                    onTextChanged: page.sync()
                }
                TextField {
                    id: ftpUser
                    width: Math.min(560, parent.width)
                    placeholderText: qsTrId("sb_ftp_user")
                    onTextChanged: page.sync()
                }
                TextField {
                    id: ftpPass
                    width: Math.min(560, parent.width)
                    echoMode: TextInput.Password
                    placeholderText: qsTrId("sb_ftp_pass")
                    onTextChanged: page.sync()
                }
                CheckBox {
                    id: ftpTls
                    text: qsTrId("sb_ftp_tls")
                    onCheckedChanged: {
                        if (checked) {
                            ftpExplicitTls.checked = false
                        }
                        page.sync()
                    }
                }
                CheckBox {
                    id: ftpExplicitTls
                    text: qsTrId("sb_ftp_explicit_tls")
                    onCheckedChanged: {
                        if (checked) {
                            ftpTls.checked = false
                        }
                        page.sync()
                    }
                }
                Text {
                    x: 28
                    width: parent.width - 28
                    text: qsTrId("sb_ftp_help")
                    wrapMode: Text.WordWrap
                    font.pointSize: 9
                }
            }

            Text {
                width: parent.width
                visible: page.providerIncomplete()
                text: qsTrId("sb_incomplete")
                wrapMode: Text.WordWrap
                color: "#a33333"
                topPadding: 4
            }
        }
    }

    ButtonGroup { id: locationGroup }
}
