import Foundation

/// How safely a target can be cleaned. Authored by hand for each target, never derived from its size: a 30 GB
/// "clean with care" stays that, and a 4 GB "do not clean" is never cleaned
enum Tier: String, Codable, Sendable, CaseIterable {
    case safe, caution, never

    var title: String {
        switch self {
        case .safe: "Safe to clean"
        case .caution: "Clean with care"
        case .never: "Do not clean"
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.shield"
        case .caution: "exclamationmark.shield"
        case .never: "xmark.shield"
        }
    }

    /// Safe items are deleted for good; careful ones go to the Trash, so a slip can be undone
    var trashes: Bool { self == .caution }
}

/// One thing macOS sweeps into "System Data": where it is, what it is, and what happens if it goes
struct Target: Sendable {
    let id: String
    let label: String
    /// `~` stands for the home folder
    let paths: [String]
    let tier: Tier
    let symbol: String
    /// Measured one folder deep, so the plugin can show what is inside
    var breakdown = false
    /// Entries of its folder that are targets of their own, left out of its size and never cleaned with it
    var excludes: [String] = []
    /// Owned by root: measured as an administrator when the user allows it, never cleaned by the plugin
    var requiresRoot = false
    /// A better way to reclaim the space, for the Terminal
    var command: String? = nil
    /// Not a folder: APFS local snapshots, listed with tmutil
    var snapshots = false
    let what: String
    let ifDeleted: String
    let advice: String

    var canClean: Bool { tier != .never && !requiresRoot && !snapshots }
}

/// The knowledge base. This file is the product; the rest is plumbing
enum Catalog {
    static let targets: [Target] = [
        // MARK: Safe
        Target(id: "user-caches", label: "Application caches", paths: ["~/Library/Caches"], tier: .safe, symbol: "archivebox",
               breakdown: true,
               what: "Scratch space every app uses for things it can rebuild: downloaded images, thumbnails, offline web content, search indexes, compiled shaders.",
               ifDeleted: "Apps are slower the first time you open them, then back to normal. A few re-download content. Nothing you made is lost.",
               advice: "The best risk-to-reward on the whole disk. Quit your apps first so nothing is mid-write."),
        Target(id: "system-caches", label: "System caches", paths: ["/Library/Caches"], tier: .safe, symbol: "archivebox",
               what: "The machine-wide caches, shared by all users and by system services.",
               ifDeleted: "Services rebuild their caches on next launch; the first boot afterwards can be a little slower.",
               advice: "Fine to clean. Parts are owned by root and stay; that part is rarely large."),
        Target(id: "user-logs", label: "User logs", paths: ["~/Library/Logs"], tier: .safe, symbol: "doc.text",
               what: "Plain-text diagnostic output from apps, going back months or years. Nothing rotates or expires it.",
               ifDeleted: "You lose the history a developer would ask for in a bug report. Nothing running is affected.",
               advice: "Clean it unless you are debugging a crash right now. Usually small."),
        Target(id: "crash-reports", label: "Crash reports",
               paths: ["~/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"], tier: .safe, symbol: "exclamationmark.octagon",
               what: "One report per app or kernel crash, as far back as the Mac has been running. A crash-happy app can leave thousands.",
               ifDeleted: "You lose the crash history. Nothing running is affected.",
               advice: "Safe to clean. If one app dominates, that is a bug worth reporting first."),
        Target(id: "xcode-derived", label: "Xcode DerivedData", paths: ["~/Library/Developer/Xcode/DerivedData"], tier: .safe, symbol: "hammer",
               what: "Intermediate build products, module caches and indexes Xcode keeps per project, long after the project is gone.",
               ifDeleted: "The next build of each project is a full clean build and Xcode re-indexes. Minutes, not hours. No source code lives here.",
               advice: "Safe, and the classic first move when Xcode misbehaves. Xcode recreates the folder."),
        Target(id: "xcode-support", label: "Xcode archives and device support",
               paths: ["~/Library/Developer/Xcode/Archives", "~/Library/Developer/Xcode/iOS DeviceSupport", "~/Library/Developer/Xcode/watchOS DeviceSupport"],
               tier: .safe, symbol: "iphone",
               what: "Debug symbols for every iOS version you ever plugged in (hundreds of MB each), plus archived builds of past releases.",
               ifDeleted: "Symbols come back the next time you attach such a device. Archives are gone: keep any you still need to submit.",
               advice: "Clean DeviceSupport for versions you no longer target. Look at Archives first if you ship apps."),
        Target(id: "gradle-cache", label: "Gradle build cache", paths: ["~/.gradle"], tier: .safe, symbol: "hammer",
               command: "rm -rf ~/.gradle/caches",
               what: "Downloaded Java and Android dependencies and cached build outputs. Versions accumulate; nothing is ever evicted.",
               ifDeleted: "The next Gradle build re-downloads its dependencies and runs cold: several minutes on a big project.",
               advice: "Safe if you are not mid-project. Daily Android builders: clear only ~/.gradle/caches."),
        Target(id: "generic-cache", label: "Command-line tool caches", paths: ["~/.cache"], tier: .safe, symbol: "terminal", breakdown: true,
               what: "Where CLI tools keep re-fetchable downloads by convention: Python wheels, Hugging Face models, Puppeteer browsers, linters.",
               ifDeleted: "Each tool re-downloads what it needs the next time you run it.",
               advice: "Safe. Look inside first: if one folder dominates, clean just that one and keep the rest warm."),
        Target(id: "npm-cache", label: "npm package cache", paths: ["~/.npm/_cacache"], tier: .safe, symbol: "shippingbox",
               command: "npm cache clean --force",
               what: "Every npm package tarball you ever installed, so repeat installs skip the network. npm never garbage-collects it.",
               ifDeleted: "The next npm install re-downloads from the registry. Slower once, then it refills.",
               advice: "Safe. npm cache clean --force does the same through npm and keeps its bookkeeping consistent."),
        Target(id: "pnpm-store", label: "pnpm content store", paths: ["~/Library/pnpm", "~/.pnpm-store"], tier: .safe, symbol: "shippingbox",
               command: "pnpm store prune",
               what: "pnpm's global store. Your projects' node_modules are hard links back into it.",
               ifDeleted: "Existing projects lose their packages and need a reinstall. More disruptive than for npm.",
               advice: "Prefer pnpm store prune: it removes only what no project references, which is nearly all of the reclaimable space."),
        Target(id: "trash", label: "Trash", paths: ["~/.Trash"], tier: .safe, symbol: "trash",
               what: "Files you already deleted. They take up disk until the Trash is emptied.",
               ifDeleted: "The files are gone for good. That was already your intent.",
               advice: "Empty it: this is space you already agreed to give up. Glance inside first for anything dragged there by accident."),

        // MARK: Caution
        Target(id: "docker", label: "Docker Desktop disk image", paths: ["~/Library/Containers/com.docker.docker"], tier: .caution, symbol: "shippingbox",
               command: "docker system prune -a --volumes",
               what: "One giant virtual disk (Docker.raw) holding the Linux VM with all your containers, images, volumes and build cache.",
               ifDeleted: "Every local image, container and volume is gone. A database kept only in a volume is gone for good. Docker rebuilds an empty VM.",
               advice: "Don't delete the folder. Prune inside Docker, then shrink the disk image under Settings > Resources. The file never shrinks by itself."),
        Target(id: "coresimulator", label: "iOS Simulator runtimes and devices", paths: ["~/Library/Developer/CoreSimulator"], tier: .caution, symbol: "ipad",
               command: "xcrun simctl delete unavailable",
               what: "The disk image of every simulated iPhone, iPad and Watch, plus the OS runtimes they boot. Each Xcode update adds runtimes.",
               ifDeleted: "All simulators reset to factory; apps and logins in them are lost. Xcode re-downloads runtimes you still need.",
               advice: "Run xcrun simctl delete unavailable first: it removes only simulators whose runtime is gone, usually most of the space."),
        Target(id: "android-sdk", label: "Android SDK", paths: ["~/Library/Android"], tier: .caution, symbol: "hammer",
               what: "Platform APIs, build tools, NDK copies and system images. Android Studio keeps every version it ever installed.",
               ifDeleted: "Android builds stop until Android Studio re-downloads the SDK, a slow first run.",
               advice: "Untick old API levels and NDK versions in Android Studio's SDK Manager instead."),
        Target(id: "android-avd", label: "Android emulator images", paths: ["~/.android"], tier: .caution, symbol: "hammer", breakdown: true,
               what: "A full Android system image plus user data for every emulator you created. Old API levels stay forever.",
               ifDeleted: "Every emulator and its apps and state are gone. Deleting adbkey makes every physical device ask to be authorized again.",
               advice: "Delete specific virtual devices in Android Studio's Device Manager, and keep ~/.android/adbkey."),
        Target(id: "ollama", label: "Ollama model weights", paths: ["~/.ollama"], tier: .caution, symbol: "brain",
               command: "ollama list   # then: ollama rm <model>",
               what: "Downloaded weights for local language models. A mid-size model is several GB; a 70B model is tens.",
               ifDeleted: "The models must be pulled again: slow and bandwidth-heavy. No conversation or setting is lost.",
               advice: "ollama rm the models you no longer use, so you keep the ones you run."),
        Target(id: "ios-backups", label: "iPhone and iPad backups", paths: ["~/Library/Application Support/MobileSync/Backup"], tier: .caution, symbol: "externaldrive",
               what: "Full local backups of iOS devices synced to this Mac, one folder per device per backup. Devices you no longer own are usually still here.",
               ifDeleted: "You can't restore that device to that point in time. An iCloud backup is unaffected.",
               advice: "Manage them in Finder under your device > Manage Backups. Never delete the only backup of a device that isn't on iCloud."),
        Target(id: "electron", label: "Electron app data (Cursor, VS Code, Discord)",
               paths: ["~/Library/Application Support/Cursor", "~/Library/Application Support/Code", "~/Library/Application Support/discord", "~/Library/Application Support/bilibili"],
               tier: .caution, symbol: "app.badge", breakdown: true,
               what: "Browser-style caches (Cache, Code Cache, GPUCache) next to real settings, extension state and workspace history.",
               ifDeleted: "Caches come back harmlessly, but the same folders hold your editor settings and extensions: the app resets.",
               advice: "Clean only the cache subfolders inside, never the parent. For editors, leave User/ alone."),
        Target(id: "wechat", label: "WeChat container", paths: ["~/Library/Containers/com.tencent.xinWeChat"], tier: .caution, symbol: "message",
               what: "Your local message history plus every image, video and file you received. WeChat never expires received media.",
               ifDeleted: "Local chat history is lost; WeChat keeps no full server copy to restore it from.",
               advice: "Clear cached media inside WeChat under Settings > General > Storage Management. Don't trash this container."),
        Target(id: "steam", label: "Steam library", paths: ["~/Library/Application Support/Steam"], tier: .caution, symbol: "gamecontroller",
               what: "Installed games, shader caches, workshop content and the Steam client.",
               ifDeleted: "Games re-download from your library. Saves not covered by Steam Cloud are lost.",
               advice: "Uninstall specific games in Steam instead; it keeps your saves and settings."),
        Target(id: "minecraft", label: "Minecraft data", paths: ["~/Library/Application Support/minecraft"], tier: .caution, symbol: "gamecontroller",
               what: "Game versions, mod libraries, resource packs and your saves folder with every world you built.",
               ifDeleted: "Versions and libraries come back from the launcher. Your worlds do not: Java Edition has no cloud backup.",
               advice: "Back up saves/ somewhere else, then clear old versions/ and unused libraries/."),
        Target(id: "firefox", label: "Firefox profile", paths: ["~/Library/Application Support/Firefox"], tier: .caution, symbol: "globe",
               what: "Bookmarks, history, passwords, cookies, extensions and a large offline cache. Old profiles from past installs often linger.",
               ifDeleted: "Everything not synced to a Firefox Account is lost.",
               advice: "Clear the cache inside Firefox. Remove stale profiles only after about:profiles shows which one is active."),
        Target(id: "adspower", label: "AdsPower browser profiles", paths: ["~/Library/Application Support/adspower_global"], tier: .caution, symbol: "person.2",
               what: "A full isolated browser profile per identity: cookies, storage, extensions and logins for each.",
               ifDeleted: "Every local profile and its sessions are gone. Only synced profiles can be pulled back.",
               advice: "Delete unused profiles inside AdsPower, and check whether your plan syncs them first."),
        Target(id: "maxon", label: "Maxon and Cinema 4D data", paths: ["~/Library/Preferences/Maxon"], tier: .caution, symbol: "cube",
               what: "Maxon's asset library, caches and preferences, kept in a folder meant for kilobytes of settings.",
               ifDeleted: "Preferences, license state and downloaded asset libraries are lost; assets need a Maxon sign-in to come back.",
               advice: "Look inside: cached asset libraries are nearly all of the size, the settings are tiny."),
        Target(id: "group-containers", label: "Group Containers", paths: ["~/Library/Group Containers"], tier: .caution, symbol: "square.stack.3d.up", breakdown: true,
               what: "Shared data for app suites: an app and its extensions, or a vendor's several apps. Messaging apps, Office and note apps keep real data here.",
               ifDeleted: "Apps lose shared state: cached messages, offline documents, sign-in tokens. Some has no other copy.",
               advice: "Per-app decisions only, and only for apps you already uninstalled. Their leftovers are the safe wins."),
        Target(id: "containers", label: "Other app containers", paths: ["~/Library/Containers"], tier: .caution, symbol: "square.stack.3d.up", breakdown: true,
               excludes: ["com.docker.docker", "com.tencent.xinWeChat"],
               what: "The sandbox of every App Store and sandboxed app: documents, settings, databases and caches, one folder per bundle id. App data, not scratch.",
               ifDeleted: "The app resets to first launch and anything it kept only locally is gone.",
               advice: "Never clean it as a whole. Look inside and remove only folders of apps you already uninstalled."),
        Target(id: "diagnostics", label: "Diagnostic archives", paths: ["/private/var/db/diagnostics", "/private/var/db/uuidtext"], tier: .caution, symbol: "waveform.path.ecg",
               requiresRoot: true,
               what: "The unified log's store: every log entry macOS kept, plus the symbol files that make them readable.",
               ifDeleted: "You can't investigate anything that already happened. macOS starts a fresh store at once.",
               advice: "Measured only. macOS caps and rotates it itself. Deleting uuidtext alone makes the remaining logs unreadable."),

        // MARK: Root-owned, measured only
        Target(id: "system-logs", label: "System logs", paths: ["/private/var/log"], tier: .safe, symbol: "doc.text", breakdown: true, requiresRoot: true,
               what: "Logs written by macOS daemons and installers. Rotated and compressed, but the archives stay a long time.",
               ifDeleted: "You lose system diagnostic history. macOS recreates what it needs at once.",
               advice: "Measured only: it is owned by root. If it is large, sudo rm /private/var/log/*.gz in Terminal clears the archives."),

        // MARK: Never
        Target(id: "messages", label: "Messages history", paths: ["~/Library/Messages"], tier: .never, symbol: "message",
               what: "The database with your whole iMessage and SMS history, plus every attachment ever sent or received.",
               ifDeleted: "Permanently gone, and with Messages in iCloud the deletion can spread to your other devices.",
               advice: "In Messages > Settings > General, keep messages for a year, or delete large attachments from conversations."),
        Target(id: "mail", label: "Mail data", paths: ["~/Library/Mail"], tier: .never, symbol: "envelope",
               what: "Apple Mail's local store: every downloaded message, attachment and mailbox index.",
               ifDeleted: "IMAP re-syncs. POP mail and On My Mac mailboxes are destroyed with no way back.",
               advice: "Stop downloading attachments in Mail's account settings, or delete large messages inside Mail."),
        Target(id: "keychains", label: "Keychains", paths: ["~/Library/Keychains"], tier: .never, symbol: "key",
               what: "Every saved password, certificate, private key and secure note of this account.",
               ifDeleted: "You are locked out of saved logins, Wi-Fi networks and certificates. Recovery ranges from tedious to impossible.",
               advice: "Never touch it. Tens of MB at most: nothing to gain."),
        Target(id: "vm", label: "Virtual memory and sleep image", paths: ["/private/var/vm"], tier: .never, symbol: "memorychip", requiresRoot: true,
               what: "Kernel swap files and sleepimage, a copy of RAM so the Mac can resume from hibernation.",
               ifDeleted: "macOS recreates them at once; interfering with swap risks kernel panics and lost work.",
               advice: "Leave it to macOS, which shrinks these itself when the disk gets tight."),
        Target(id: "var-folders", label: "Per-boot temporary state", paths: ["/private/var/folders"], tier: .never, symbol: "clock", requiresRoot: true,
               what: "Temporary folders of processes running right now: caches, sockets and scratch files for live apps.",
               ifDeleted: "Running apps lose files out from under themselves: crashes and lost unsaved work.",
               advice: "A restart clears what is stale."),
        Target(id: "spotlight", label: "Spotlight index", paths: ["/System/Volumes/Data/.Spotlight-V100"], tier: .never, symbol: "magnifyingglass", requiresRoot: true,
               command: "sudo mdutil -E /   # rebuilds; saves nothing",
               what: "The search index behind Spotlight, Siri suggestions and Finder search. A few GB on a large volume is normal.",
               ifDeleted: "macOS reindexes the whole disk for hours, and search is broken until it finishes. The index comes back the same size.",
               advice: "Not a space win. Rebuild with mdutil only if search is broken."),
        Target(id: "snapshots", label: "APFS local snapshots", paths: [], tier: .never, symbol: "clock.arrow.circlepath",
               command: "tmutil listlocalsnapshots /", snapshots: true,
               what: "Point-in-time snapshots Time Machine keeps on the startup disk between backups. Invisible in Finder, and the usual reason System Data won't go down.",
               ifDeleted: "You lose local restore points. macOS purges them itself as the disk fills.",
               advice: "Check, don't delete: macOS thins them under disk pressure."),
    ]

    static func target(_ id: String) -> Target? { targets.first { $0.id == id } }

    static func expand(_ path: String) -> String {
        path.hasPrefix("~") ? NSHomeDirectory() + path.dropFirst() : path
    }

    static func collapse(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
