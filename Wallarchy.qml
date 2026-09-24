import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import qs.Modals.FileBrowser

PluginComponent {
    id: root

    property var popoutService: null

    readonly property string apiBase: "https://wallhaven.cc/api/v1"
    readonly property string homeDir: Quickshell.env("HOME")
    readonly property string defaultDownloadDir: {
        if (SessionData.wallpaperCyclingFolderPath)
            return String(SessionData.wallpaperCyclingFolderPath).replace(/^file:\/\//, "")

        let current = String(SessionData.wallpaperPath || "").replace(/^file:\/\//, "")
        if (current && !current.startsWith("#") && current.lastIndexOf("/") > 0)
            return current.slice(0, current.lastIndexOf("/"))

        return homeDir + "/Pictures"
    }

    property string downloadDir: (pluginData && pluginData.downloadDir !== undefined && String(pluginData.downloadDir).trim() !== "")
        ? String(pluginData.downloadDir).replace(/^file:\/\//, "")
        : defaultDownloadDir

    property string query: (pluginData && pluginData.query !== undefined) ? String(pluginData.query) : ""
    property string categories: (pluginData && pluginData.categories !== undefined) ? String(pluginData.categories) : "111"
    property string sorting: (pluginData && pluginData.sorting !== undefined) ? String(pluginData.sorting) : "relevance"
    property string atleast: (pluginData && pluginData.atleast !== undefined) ? String(pluginData.atleast) : ""

    property bool loading: false
    property bool applying: false
    property bool loadingMore: false
    property string errorText: ""
    property int page: 1
    property int requestSerial: 0
    property int activeRequestSerial: 0
    property string selectedPresetTag: ""
    property int lastResultTotal: -1

    property var pendingPhoto: null
    property string pendingLocalPath: ""

    property var tags: [
        "nature", "landscape", "minimal", "space", "mountains", "ocean",
        "forest", "city", "abstract", "dark", "sunset", "cyberpunk",
        "architecture", "aerial", "animals", "cars"
    ]

    property var categoryNames: ["General", "Anime", "People"]

    property var sortingOptions: [
        { "label": "Relevance", "value": "relevance" },
        { "label": "Top", "value": "toplist" },
        { "label": "Newest", "value": "date_added" },
        { "label": "Views", "value": "views" },
        { "label": "Favorites", "value": "favorites" }
    ]

    property var resolutionOptions: [
        { "label": "Any size", "value": "" },
        { "label": "1080p+", "value": "1920x1080" },
        { "label": "1440p+", "value": "2560x1440" },
        { "label": "4K+", "value": "3840x2160" }
    ]

    ListModel {
        id: photoModel
    }

    function safeText(value, maxLength) {
        if (value === undefined || value === null)
            return ""
        const flat = String(value).replace(/\s+/g, " ").trim()
        const limit = maxLength || 160
        return flat.length > limit ? flat.slice(0, limit - 1) + "…" : flat
    }

    function normalizeCategories(value) {
        let bits = String(value || "111").replace(/[^01]/g, "")
        while (bits.length < 3)
            bits += "0"
        bits = bits.slice(0, 3)
        return bits === "000" ? "111" : bits
    }

    function categoryEnabled(index) {
        return normalizeCategories(categories).charAt(index) === "1"
    }

    function toggleCategory(index) {
        let bits = normalizeCategories(categories).split("")
        const enabledCount = bits.filter(bit => bit === "1").length
        if (bits[index] === "1" && enabledCount === 1)
            return

        bits[index] = bits[index] === "1" ? "0" : "1"
        categories = bits.join("")
        saveSetting("categories", categories)
        reload()
    }

    function optionLabel(options, value, fallback) {
        for (let i = 0; i < options.length; i++) {
            if (options[i].value === value)
                return options[i].label
        }
        return fallback
    }

    function cycleOption(options, value) {
        for (let i = 0; i < options.length; i++) {
            if (options[i].value === value)
                return options[(i + 1) % options.length].value
        }
        return options[0].value
    }

    function saveSetting(key, value) {
        if (pluginService)
            pluginService.savePluginData(pluginId, key, value)
    }

    function submitQuery(value, presetTag) {
        const nextQuery = safeText(value, 120).trim()
        query = nextQuery
        selectedPresetTag = presetTag || ""
        saveSetting("query", query)
        reload()
    }

    function setQuery(value) {
        submitQuery(value, "")
    }

    function normalizeLocalPath(value) {
        let path = String(value || "").trim().replace(/^file:\/\//, "")
        if (path.length > 1)
            path = path.replace(/\/+$/, "")
        return path
    }

    function setDownloadDir(value) {
        const path = normalizeLocalPath(value)
        if (!path)
            return
        downloadDir = path
        saveSetting("downloadDir", downloadDir)
        ToastService.showInfo("Download folder updated")
    }

    function openDownloadFolderPicker() {
        downloadFolderBrowser.open()
    }

    function selectTag(tag) {
        submitQuery(tag, tag)
    }

    function cycleSorting() {
        sorting = cycleOption(sortingOptions, sorting)
        saveSetting("sorting", sorting)
        reload()
    }

    function cycleResolution() {
        atleast = cycleOption(resolutionOptions, atleast)
        saveSetting("atleast", atleast)
        reload()
    }

    function searchUrlFor(targetPage, randomMode, queryValue, categoriesValue, sortingValue, atleastValue) {
        const params = []
        params.push("categories=" + encodeURIComponent(normalizeCategories(categoriesValue)))
        params.push("purity=100")

        if (atleastValue)
            params.push("atleast=" + encodeURIComponent(atleastValue))
        if (queryValue)
            params.push("q=" + encodeURIComponent(queryValue))

        if (randomMode) {
            params.push("sorting=random")
        } else {
            const sortValue = sortingValue || "relevance"
            params.push("sorting=" + encodeURIComponent(sortValue))
            params.push("order=desc")
            if (sortValue === "toplist")
                params.push("topRange=1M")
            params.push("page=" + String(targetPage || 1))
        }

        return apiBase + "/search?" + params.join("&")
    }

    function currentSearchUrl(targetPage, randomMode) {
        return searchUrlFor(
            targetPage,
            randomMode,
            String(query || ""),
            String(categories || "111"),
            String(sorting || "relevance"),
            String(atleast || "")
        )
    }

    function curlCommand(url, downloadPath) {
        const args = [
            "curl", "-fsSL",
            "--connect-timeout", "10",
            "--max-time", downloadPath ? "120" : "30",
            "--retry", "4",
            "--retry-delay", "2",
            "--retry-max-time", downloadPath ? "120" : "45",
            "--retry-all-errors",
            "--user-agent", "WallarchyDMS/1.0.0"
        ]

        if (downloadPath) {
            args.push("--remove-on-error")
            args.push("-o")
            args.push(downloadPath)
        }

        args.push(url)
        return args
    }

    function friendlyNetworkError(raw, fallback) {
        const text = safeText(raw, 180)
        if (text.indexOf("522") !== -1)
            return "Wallhaven is temporarily unreachable (HTTP 522). Please retry."
        if (text.indexOf("Could not resolve host") !== -1)
            return "Could not reach Wallhaven. Check your internet or DNS, then retry."
        if (text.indexOf("timed out") !== -1 || text.indexOf("Timeout") !== -1)
            return "Wallhaven timed out. Please retry."
        return text || fallback
    }

    function rowFromApi(item) {
        if (!item || !item.id || !item.path)
            return null

        const thumbs = item.thumbs || {}
        const colors = item.colors || []
        const resolution = safeText(item.resolution || "", 32)
        const category = safeText(item.category || "", 24)
        const label = resolution + (resolution && category ? " · " : "") + category

        return {
            "wallpaperId": String(item.id),
            "thumbUrl": String(thumbs.small || thumbs.large || item.path),
            "previewUrl": String(thumbs.large || thumbs.small || item.path),
            "imageUrl": String(item.path),
            "dominantColor": colors.length > 0 ? String(colors[0]) : String(Theme.surfaceContainerHigh),
            "label": label,
            "sourceUrl": String(item.url || "https://wallhaven.cc/w/" + item.id),
            "extension": item.file_type === "image/png" ? "png" : "jpg"
        }
    }

    function apiErrorMessage(value) {
        if (value === undefined || value === null)
            return ""
        if (typeof value === "string")
            return safeText(value, 220)
        try {
            return safeText(JSON.stringify(value), 220)
        } catch (error) {
            return safeText(String(value), 220)
        }
    }

    function parsePayload(raw) {
        try {
            const parsed = JSON.parse(raw)
            if (parsed && Array.isArray(parsed.data))
                return parsed

            if (parsed && parsed.error !== undefined)
                errorText = "Wallhaven API: " + apiErrorMessage(parsed.error)
            else
                errorText = "Wallhaven returned an unexpected response."
            return null
        } catch (error) {
            errorText = "Wallhaven returned invalid JSON."
            return null
        }
    }

    function parseResponse(raw) {
        const parsed = parsePayload(raw)
        return parsed ? parsed.data : []
    }

    function appendResponse(raw) {
        const parsed = parsePayload(raw)
        if (!parsed)
            return

        const rows = parsed.data
        if (parsed.meta && parsed.meta.total !== undefined) {
            const total = Number(parsed.meta.total)
            lastResultTotal = isFinite(total) ? total : -1
        }

        if (rows.length === 0) {
            if (photoModel.count === 0 && errorText === "")
                errorText = query
                    ? "Wallhaven returned 0 results for ‘" + query + "’."
                    : "No wallpapers matched these filters."
            return
        }

        for (let i = 0; i < rows.length; i++) {
            const row = rowFromApi(rows[i])
            if (row)
                photoModel.append(row)
        }
    }

    function runSearch(targetPage, appendMode) {
        const snapshotQuery = String(query || "")
        const snapshotCategories = String(categories || "111")
        const snapshotSorting = String(sorting || "relevance")
        const snapshotAtleast = String(atleast || "")
        const requestPage = targetPage || 1
        const serial = ++requestSerial
        activeRequestSerial = serial

        if (!appendMode) {
            page = 1
            photoModel.clear()
            loading = true
            loadingMore = false
        } else {
            loadingMore = true
        }

        errorText = ""
        lastResultTotal = -1

        const url = searchUrlFor(
            requestPage,
            false,
            snapshotQuery,
            snapshotCategories,
            snapshotSorting,
            snapshotAtleast
        )

        Proc.runCommand(
            "wallarchyDms.search." + String(serial),
            curlCommand(url, ""),
            (stdout, exitCode) => {
                // A newer search/filter request supersedes this response completely.
                if (serial !== root.activeRequestSerial)
                    return

                root.loading = false
                root.loadingMore = false

                if (exitCode !== 0) {
                    if (appendMode)
                        root.page = Math.max(1, root.page - 1)
                    root.errorText = root.friendlyNetworkError(stdout, "Wallhaven request failed.")
                    return
                }

                root.appendResponse(stdout)
            },
            0,
            45000,
            root
        )
    }

    function reload() {
        runSearch(1, false)
    }

    function loadMore() {
        if (loading || loadingMore || photoModel.count === 0)
            return

        page += 1
        runSearch(page, true)
    }

    function randomNow() {
        if (applying || randomProcess.running)
            return

        errorText = ""
        applying = true
        randomProcess.command = curlCommand(currentSearchUrl(1, true), "")
        randomProcess.running = true
    }

    function applyPhoto(photo) {
        if (!photo || !photo.imageUrl || !photo.wallpaperId || applying)
            return

        const targetDir = normalizeLocalPath(downloadDir || defaultDownloadDir)
        if (!targetDir) {
            errorText = "Choose a download folder first."
            ToastService.showError(errorText)
            return
        }

        pendingPhoto = photo
        pendingLocalPath = targetDir + "/wallhaven-" + photo.wallpaperId + "." + (photo.extension || "jpg")
        applying = true
        errorText = ""

        mkdirProcess.command = ["mkdir", "-p", targetDir]
        mkdirProcess.running = true
    }

    function failApply(message) {
        applying = false
        pendingPhoto = null
        pendingLocalPath = ""
        errorText = message
        ToastService.showError(message)
    }

    function applyByIndex(index) {
        if (index < 0 || index >= photoModel.count)
            return
        applyPhoto(photoModel.get(index))
    }

    Component.onCompleted: {
        categories = normalizeCategories(categories)

        // v1.0/1.1 shipped with restrictive browse defaults. If those values were
        // persisted unchanged, migrate them once to normal free-text search defaults.
        if (categories === "100" && sorting === "toplist" && atleast === "1920x1080") {
            categories = "111"
            sorting = "relevance"
            atleast = ""
            saveSetting("categories", categories)
            saveSetting("sorting", sorting)
            saveSetting("atleast", atleast)
        }

        downloadDir = normalizeLocalPath(downloadDir || defaultDownloadDir)
        Qt.callLater(reload)
    }

    FileBrowserModal {
        id: downloadFolderBrowser
        browserTitle: "Choose wallpaper download folder"
        browserIcon: "folder"
        browserType: "wallpaper"
        folderMode: true
        showHiddenFiles: true
        allowStacking: true
        onFileSelected: path => {
            root.setDownloadDir(path)
            close()
        }
    }

    Process {
        id: randomProcess
        command: []

        stdout: StdioCollector {
            id: randomOutput
            waitForEnd: true
        }

        stderr: StdioCollector {
            id: randomError
            waitForEnd: true
        }

        onExited: function(code) {
            if (code !== 0) {
                root.applying = false
                root.errorText = root.friendlyNetworkError(randomError.text, "Could not fetch a random wallpaper.")
                return
            }

            const rows = root.parseResponse(randomOutput.text)
            if (rows.length === 0) {
                root.applying = false
                root.errorText = "No random wallpaper matched these filters."
                return
            }

            const photo = root.rowFromApi(rows[0])
            root.applying = false
            root.applyPhoto(photo)
        }
    }

    Process {
        id: mkdirProcess
        command: []

        onExited: function(code) {
            if (code !== 0) {
                root.failApply("Could not create the wallpaper folder.")
                return
            }

            downloadProcess.command = root.curlCommand(root.pendingPhoto.imageUrl, root.pendingLocalPath)
            downloadProcess.running = true
        }
    }

    Process {
        id: downloadProcess
        command: []

        stderr: StdioCollector {
            id: downloadError
            waitForEnd: true
        }

        onExited: function(code) {
            if (code !== 0) {
                root.failApply(root.friendlyNetworkError(downloadError.text, "Wallpaper download failed."))
                return
            }

            setWallpaperProcess.command = ["dms", "ipc", "call", "wallpaper", "set", root.pendingLocalPath]
            setWallpaperProcess.running = true
        }
    }

    Process {
        id: setWallpaperProcess
        command: []

        stderr: StdioCollector {
            id: setWallpaperError
            waitForEnd: true
        }

        onExited: function(code) {
            if (code !== 0) {
                root.failApply(root.safeText(setWallpaperError.text, 180) || "DMS could not set the wallpaper.")
                return
            }

            if (pluginService && root.pendingPhoto) {
                pluginService.savePluginState(pluginId, "currentWallpaper", {
                    "id": root.pendingPhoto.wallpaperId,
                    "path": root.pendingLocalPath,
                    "source": root.pendingPhoto.sourceUrl
                })
            }

            ToastService.showInfo("Wallpaper applied")
            root.applying = false
            root.pendingPhoto = null
            root.pendingLocalPath = ""
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                name: root.applying ? "downloading" : "wallpaper"
                size: Theme.iconSize - 4
                color: root.applying ? Theme.primary : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: root.query !== ""
                text: root.query
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        DankIcon {
            name: root.applying ? "downloading" : "wallpaper"
            size: Theme.iconSize - 4
            color: root.applying ? Theme.primary : Theme.surfaceText
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }

    popoutWidth: 920
    popoutHeight: 680

    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: "Wallarchy"
            detailsText: root.applying ? "Downloading and applying wallpaper…" : ""
            showCloseButton: true

            Column {
                width: parent.width
                spacing: Theme.spacingM

                Row {
                    width: parent.width
                    spacing: Theme.spacingS
                }

                Flickable {
                    width: parent.width
                    height: 38
                    contentWidth: categoryRow.implicitWidth
                    clip: true
                    flickableDirection: Flickable.HorizontalFlick

                    Row {
                        id: categoryRow
                        spacing: Theme.spacingS

                        Repeater {
                            model: root.categoryNames

                            delegate: Rectangle {
                                required property int index
                                required property string modelData

                                width: categoryText.implicitWidth + Theme.spacingM * 2
                                height: 34
                                radius: 17
                                color: root.categoryEnabled(index) ? Theme.primary : (categoryArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh)

                                StyledText {
                                    id: categoryText
                                    anchors.centerIn: parent
                                    text: modelData
                                    color: root.categoryEnabled(index) ? Theme.onPrimary : Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                }

                                MouseArea {
                                    id: categoryArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.toggleCategory(index)
                                }
                            }
                        }

                        Rectangle {
                            width: 1
                            height: 24
                            anchors.verticalCenter: parent.verticalCenter
                            color: Theme.outline
                        }

                        Rectangle {
                            width: allText.implicitWidth + Theme.spacingM * 2
                            height: 34
                            radius: 17
                            color: root.query === "" ? Theme.primary : (allArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh)

                            StyledText {
                                id: allText
                                anchors.centerIn: parent
                                text: "All"
                                color: root.query === "" ? Theme.onPrimary : Theme.surfaceText
                                font.pixelSize: Theme.fontSizeSmall
                            }

                            MouseArea {
                                id: allArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    searchInput.text = ""
                                    root.selectTag("")
                                }
                            }
                        }

                        Repeater {
                            model: root.tags

                            delegate: Rectangle {
                                required property string modelData

                                width: tagText.implicitWidth + Theme.spacingM * 2
                                height: 34
                                radius: 17
                                color: root.selectedPresetTag === modelData ? Theme.primary : (tagArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh)

                                StyledText {
                                    id: tagText
                                    anchors.centerIn: parent
                                    text: modelData
                                    color: root.selectedPresetTag === modelData ? Theme.onPrimary : Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                }

                                MouseArea {
                                    id: tagArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        searchInput.text = modelData
                                        root.selectTag(modelData)
                                    }
                                }
                            }
                        }
                    }
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    Rectangle {
                        width: sortLabel.implicitWidth + Theme.spacingM * 2
                        height: 36
                        radius: Theme.cornerRadius
                        color: sortArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                        Row {
                            anchors.centerIn: parent
                            spacing: Theme.spacingXS

                            DankIcon {
                                name: "sort"
                                size: 17
                                color: Theme.surfaceVariantText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                id: sortLabel
                                text: root.optionLabel(root.sortingOptions, root.sorting, "Relevance")
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeSmall
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        MouseArea {
                            id: sortArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.cycleSorting()
                        }
                    }

                    Rectangle {
                        width: resolutionLabel.implicitWidth + Theme.spacingM * 2
                        height: 36
                        radius: Theme.cornerRadius
                        color: resolutionArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                        Row {
                            anchors.centerIn: parent
                            spacing: Theme.spacingXS

                            DankIcon {
                                name: "photo_size_select_large"
                                size: 17
                                color: Theme.surfaceVariantText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                id: resolutionLabel
                                text: root.optionLabel(root.resolutionOptions, root.atleast, "Any size")
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeSmall
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        MouseArea {
                            id: resolutionArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.cycleResolution()
                        }
                    }

                    Item {
                        width: 1
                        height: 1
                    }

                    Rectangle {
                        width: randomLabel.implicitWidth + Theme.spacingM * 2 + 22
                        height: 36
                        radius: Theme.cornerRadius
                        color: root.applying ? Theme.surfaceContainerHigh : (randomArea.containsMouse ? Theme.primary : Theme.surfaceContainerHighest)
                        opacity: root.applying ? 0.55 : 1.0

                        Row {
                            anchors.centerIn: parent
                            spacing: Theme.spacingXS

                            DankIcon {
                                name: "shuffle"
                                size: 17
                                color: randomArea.containsMouse && !root.applying ? Theme.onPrimary : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                id: randomLabel
                                text: "Surprise me"
                                color: randomArea.containsMouse && !root.applying ? Theme.onPrimary : Theme.surfaceText
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        MouseArea {
                            id: randomArea
                            anchors.fill: parent
                            enabled: !root.applying
                            hoverEnabled: enabled
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: root.randomNow()
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 46
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacingM
                        anchors.rightMargin: Theme.spacingS
                        spacing: Theme.spacingS

                        DankIcon {
                            name: "folder"
                            size: 18
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            width: parent.width - chooseFolderButton.width - Theme.spacingS * 2 - 18
                            spacing: 1
                            anchors.verticalCenter: parent.verticalCenter

                            StyledText {
                                text: "Download folder"
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                            }

                            StyledText {
                                width: parent.width
                                text: root.downloadDir
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                elide: Text.ElideMiddle
                            }
                        }

                        Rectangle {
                            id: chooseFolderButton
                            width: 96
                            height: 34
                            anchors.verticalCenter: parent.verticalCenter
                            radius: Theme.cornerRadius
                            color: chooseFolderArea.containsMouse ? Theme.primary : Theme.surfaceContainerHighest

                            StyledText {
                                anchors.centerIn: parent
                                text: "Change"
                                color: chooseFolderArea.containsMouse ? Theme.onPrimary : Theme.surfaceText
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                            }

                            MouseArea {
                                id: chooseFolderArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.openDownloadFolderPicker()
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 380
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainer
                    clip: true

                    GridView {
                        id: grid
                        anchors.fill: parent
                        anchors.margins: Theme.spacingXS
                        clip: true
                        model: photoModel
                        cellWidth: Math.max(180, Math.floor(width / 4))
                        cellHeight: 142

                        delegate: Item {
                            id: card
                            required property int index
                            required property string wallpaperId
                            required property string thumbUrl
                            required property string previewUrl
                            required property string imageUrl
                            required property string dominantColor
                            required property string label
                            required property string sourceUrl
                            required property string extension

                            width: grid.cellWidth
                            height: grid.cellHeight

                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 5
                                radius: Theme.cornerRadius
                                color: card.dominantColor
                                clip: true
                                border.width: cardArea.containsMouse ? 2 : 0
                                border.color: Theme.primary

                                Image {
                                    anchors.fill: parent
                                    source: card.thumbUrl
                                    asynchronous: true
                                    cache: true
                                    fillMode: Image.PreserveAspectCrop
                                    sourceSize.width: 420
                                    opacity: status === Image.Ready ? 1.0 : 0.0

                                    Behavior on opacity {
                                        NumberAnimation { duration: 140 }
                                    }
                                }

                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    height: 34
                                    color: "#99000000"
                                    visible: cardArea.containsMouse

                                    StyledText {
                                        anchors.fill: parent
                                        anchors.leftMargin: 8
                                        anchors.rightMargin: 8
                                        verticalAlignment: Text.AlignVCenter
                                        text: card.label
                                        color: "white"
                                        font.pixelSize: Theme.fontSizeSmall
                                        elide: Text.ElideRight
                                    }
                                }

                                Rectangle {
                                    anchors.centerIn: parent
                                    width: applyText.implicitWidth + Theme.spacingM * 2
                                    height: 34
                                    radius: 17
                                    color: Theme.primary
                                    visible: cardArea.containsMouse && !root.applying

                                    StyledText {
                                        id: applyText
                                        anchors.centerIn: parent
                                        text: "Apply"
                                        color: Theme.onPrimary
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                    }
                                }

                                MouseArea {
                                    id: cardArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: !root.applying
                                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: root.applyByIndex(card.index)
                                }
                            }
                        }
                    }

                    Column {
                        anchors.centerIn: parent
                        spacing: Theme.spacingS
                        visible: root.loading && photoModel.count === 0

                        DankIcon {
                            name: "progress_activity"
                            size: 32
                            color: Theme.primary
                            anchors.horizontalCenter: parent.horizontalCenter

                            RotationAnimation on rotation {
                                from: 0
                                to: 360
                                duration: 900
                                loops: Animation.Infinite
                                running: parent.visible
                            }
                        }

                        StyledText {
                            text: "Loading wallpapers…"
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeMedium
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }

                    Column {
                        anchors.centerIn: parent
                        width: parent.width - Theme.spacingXL * 2
                        visible: !root.loading && photoModel.count === 0 && root.errorText !== ""
                        spacing: Theme.spacingM

                        StyledText {
                            width: parent.width
                            text: root.errorText
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeMedium
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                        }

                        Rectangle {
                            width: 100
                            height: 36
                            anchors.horizontalCenter: parent.horizontalCenter
                            radius: Theme.cornerRadius
                            color: retryArea.containsMouse ? Theme.primary : Theme.surfaceContainerHighest

                            Row {
                                anchors.centerIn: parent
                                spacing: Theme.spacingXS

                                DankIcon {
                                    name: "refresh"
                                    size: 17
                                    color: retryArea.containsMouse ? Theme.onPrimary : Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: "Retry"
                                    color: retryArea.containsMouse ? Theme.onPrimary : Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                id: retryArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.reload()
                            }
                        }
                    }
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    StyledText {
                        width: parent.width - loadMoreButton.width - Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.errorText !== "" && photoModel.count > 0
                            ? root.errorText
                            : (photoModel.count > 0
                                ? photoModel.count + " loaded" + (root.lastResultTotal >= 0 ? " · " + root.lastResultTotal + " total" : "")
                                : "")
                        color: root.errorText !== "" ? Theme.error : Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                        elide: Text.ElideRight
                    }

                    Rectangle {
                        id: loadMoreButton
                        width: 110
                        height: 36
                        radius: Theme.cornerRadius
                        color: loadMoreArea.containsMouse && !root.loadingMore ? Theme.primary : Theme.surfaceContainerHigh
                        opacity: (photoModel.count > 0 && !root.loading) ? 1.0 : 0.45

                        StyledText {
                            anchors.centerIn: parent
                            text: root.loadingMore ? "Loading…" : "Load more"
                            color: loadMoreArea.containsMouse && !root.loadingMore ? Theme.onPrimary : Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                        }

                        MouseArea {
                            id: loadMoreArea
                            anchors.fill: parent
                            enabled: photoModel.count > 0 && !root.loading && !root.loadingMore
                            hoverEnabled: enabled
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: root.loadMore()
                        }
                    }
                }
            }
        }
    }
}
