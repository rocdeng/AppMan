import XCTest
@testable import AppManCore

final class UpdateRecipeCoverageTests: XCTestCase {
    func testBundledRecipesCoverScannedSelfInstalledApps() throws {
        let recipes = try FileUpdateRecipeStore(
            builtInDirectoryURLs: [
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent("Resources/UpdateRecipes", isDirectory: true),
            ],
            userDirectoryURL: temporaryRecipeDirectory()
        ).load()

        let missingBundleIdentifiers = scannedSelfInstalledApps.compactMap { app in
            UpdateRecipeMatcher.bestRecipe(for: app, in: recipes) == nil
                ? app.bundleIdentifier
                : nil
        }

        XCTAssertEqual(missingBundleIdentifiers, [])
    }

    func testBundledRecipesDeclareDownloadRules() throws {
        let recipeDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/UpdateRecipes", isDirectory: true)
        let recipeURLs = try FileManager.default.contentsOfDirectory(
            at: recipeDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }

        let missingDownloadKeys = try recipeURLs.compactMap { url -> String? in
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return url.lastPathComponent
            }
            return object.keys.contains("download") ? nil : url.lastPathComponent
        }

        XCTAssertEqual(missingDownloadKeys.sorted(), [])
    }

    func testKnownPublicRecipesDeclareVersionChecks() throws {
        let recipeDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/UpdateRecipes", isDirectory: true)
        let recipes = try FileUpdateRecipeStore(
            builtInDirectoryURLs: [recipeDirectory],
            userDirectoryURL: temporaryRecipeDirectory()
        ).load()
        let recipesByID = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
        let expectedCheckedRecipeIDs = [
            "com.openai.codex",
            "com.google.android.studio",
            "com.google.Chrome",
            "com.microsoft.edgemac",
            "com.tencent.qq",
            "com.tencent.Lemon",
            "com.tencent.xinWeChat",
            "dev.warp.Warp-Stable",
            "com.todesktop.241012ess7yxs0e",
            "com.xingyuzhong.deepseekgui",
            "com.ccswitch.desktop",
            "party.mihomo.app",
            "app.omlx",
            "com.docker.docker",
            "com.jgraph.drawio.desktop",
            "download.mkvtoolnix.MKVToolNix",
            "com.openworker.desktop",
            "org.openscad.OpenSCAD",
            "org.torproject.torbrowser",
            "dev.kiro.desktop",
            "dev.kdrag0n.MacVirt",
            "com.netease.uuremote",
        ]

        let missingChecks = expectedCheckedRecipeIDs.filter { id in
            recipesByID[id]?.checks.isEmpty != false
        }

        XCTAssertEqual(missingChecks, [])
    }

    private var scannedSelfInstalledApps: [AppRecord] {
        [
            makeApp(name: "Android Studio", bundleIdentifier: "com.google.android.studio"),
            makeApp(name: "AppCleaner", bundleIdentifier: "net.freemacsoft.AppCleaner"),
            makeApp(name: "Autodesk Fusion", bundleIdentifier: "com.autodesk.dls.streamer.scriptapp.Autodesk-Fusion"),
            makeApp(
                name: "Autodesk Fusion Service Utility",
                bundleIdentifier: "com.autodesk.dls.streamer.scriptapp.Autodesk-Fusion-Service-Utility"
            ),
            makeApp(name: "Avast", bundleIdentifier: "com.avast.AAFM"),
            makeApp(name: "BaiduNetdisk_mac", bundleIdentifier: "com.baidu.BaiduNetdisk-mac"),
            makeApp(name: "Bambu Studio", bundleIdentifier: "com.bambulab.bambu-studio"),
            makeApp(name: "BetterDisplay", bundleIdentifier: "pro.betterdisplay.BetterDisplay"),
            makeApp(name: "BetterTouchTool", bundleIdentifier: "com.hegenberg.BetterTouchTool"),
            makeApp(name: "Beyond Compare", bundleIdentifier: "com.ScooterSoftware.BeyondCompare"),
            makeApp(name: "BLEUnlock", bundleIdentifier: "jp.sone.BLEUnlock"),
            makeApp(name: "CC Switch", bundleIdentifier: "com.ccswitch.desktop"),
            makeApp(name: "Cherry Studio", bundleIdentifier: "com.kangfenmao.CherryStudio"),
            makeApp(name: "Clash Verge", bundleIdentifier: "io.github.clash-verge-rev.clash-verge-rev"),
            makeApp(name: "Clash Party", bundleIdentifier: "party.mihomo.app"),
            makeApp(name: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop"),
            makeApp(name: "Claude Code URL Handler", bundleIdentifier: "com.anthropic.claude-code-url-handler"),
            makeApp(name: "CocosDashboard", bundleIdentifier: "com.cocos.dashboard"),
            makeApp(name: "Code", bundleIdentifier: "com.microsoft.VSCode"),
            makeApp(name: "Codex", bundleIdentifier: "com.openai.codex"),
            makeApp(name: "com.avast.av.uninstaller", bundleIdentifier: "com.avast.av.uninstaller"),
            makeApp(name: "ComfyUI", bundleIdentifier: "com.todesktop.241012ess7yxs0e"),
            makeApp(name: "CoolEmby", bundleIdentifier: "dev.coolmby.coolemby"),
            makeApp(name: "CoolMega", bundleIdentifier: "com.futuredream.coolmega"),
            makeApp(name: "CrossOver", bundleIdentifier: "com.codeweavers.CrossOver"),
            makeApp(name: "Devin", bundleIdentifier: "com.exafunction.windsurf"),
            makeApp(name: "Docker", bundleIdentifier: "com.docker.docker"),
            makeApp(name: "draw.io", bundleIdentifier: "com.jgraph.drawio.desktop"),
            makeApp(name: "FlClash", bundleIdentifier: "com.follow.clash"),
            makeApp(name: "Fork", bundleIdentifier: "com.DanPristupov.Fork"),
            makeApp(name: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty"),
            makeApp(name: "Godot", bundleIdentifier: "org.godotengine.godot"),
            makeApp(name: "Google Chrome", bundleIdentifier: "com.google.Chrome"),
            makeApp(name: "IINA", bundleIdentifier: "com.colliderli.iina"),
            makeApp(name: "iTerm2", bundleIdentifier: "com.googlecode.iterm2"),
            makeApp(name: "Keka", bundleIdentifier: "com.aone.keka"),
            makeApp(name: "Kun", bundleIdentifier: "com.xingyuzhong.deepseekgui"),
            makeApp(name: "Lark", bundleIdentifier: "com.electron.lark"),
            makeApp(name: "LlamaBarnNG", bundleIdentifier: "app.llamabarnng.LlamaBarnNG"),
            makeApp(name: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac"),
            makeApp(name: "MKVToolNix", bundleIdentifier: "download.mkvtoolnix.MKVToolNix"),
            makeApp(name: "modelQL", bundleIdentifier: "com.dengpeng.modelQL"),
            makeApp(name: "Obsidian", bundleIdentifier: "md.obsidian"),
            makeApp(name: "Ollama", bundleIdentifier: "com.electron.ollama"),
            makeApp(name: "oMLX", bundleIdentifier: "app.omlx"),
            makeApp(name: "OpenSCAD", bundleIdentifier: "org.openscad.OpenSCAD"),
            makeApp(name: "OpenWorker", bundleIdentifier: "com.openworker.desktop"),
            makeApp(name: "pcsuite", bundleIdentifier: "com.vivo.pcsuite"),
            makeApp(name: "Pen", bundleIdentifier: "dev.pencil.desktop"),
            makeApp(name: "QQ", bundleIdentifier: "com.tencent.qq"),
            makeApp(name: "Remove Autodesk Fusion", bundleIdentifier: "com.autodesk.dls.streamer.scriptapp.Remove-Autodesk-Fusion"),
            makeApp(name: "skills-manager", bundleIdentifier: "com.agentskills.desktop"),
            makeApp(name: "Sniffnet", bundleIdentifier: "io.github.gyulyvgc.sniffnet"),
            makeApp(name: "Stats", bundleIdentifier: "eu.exelban.Stats"),
            makeApp(name: "Sword Shield Dog Test", bundleIdentifier: "com.test.dog"),
            makeApp(name: "Synergy", bundleIdentifier: "com.symless.synergy"),
            makeApp(name: "Tabbit", bundleIdentifier: "com.tabbit-ai.Tabbit"),
            makeApp(name: "Tabby", bundleIdentifier: "org.tabby"),
            makeApp(name: "Telegram", bundleIdentifier: "ru.keepcoder.Telegram"),
            makeApp(name: "Tencent Lemon", bundleIdentifier: "com.tencent.Lemon"),
            makeApp(name: "Transmit", bundleIdentifier: "com.panic.Transmit"),
            makeApp(name: "Typeless", bundleIdentifier: "now.typeless.desktop"),
            makeApp(name: "Unsloth Studio", bundleIdentifier: "ai.unsloth.studio"),
            makeApp(name: "v2rayN", bundleIdentifier: "2dust.v2rayN"),
            makeApp(name: "VoiceInput", bundleIdentifier: "com.voiceinput.app"),
            makeApp(name: "Warp", bundleIdentifier: "dev.warp.Warp-Stable"),
            makeApp(name: "WeChat", bundleIdentifier: "com.tencent.xinWeChat"),
            makeApp(name: "wpsoffice", bundleIdentifier: "com.kingsoft.wpsoffice.mac"),
            makeApp(name: "xiezuo", bundleIdentifier: "com.kingsoft.xiezuo"),
        ]
    }

    private func makeApp(name: String, bundleIdentifier: String) -> AppRecord {
        AppRecord(
            id: bundleIdentifier,
            name: name,
            bundleIdentifier: bundleIdentifier,
            shortVersion: "1.0",
            buildVersion: nil,
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            sizeBytes: 1,
            installSource: .manual(reason: "unknown")
        )
    }

    private func temporaryRecipeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
