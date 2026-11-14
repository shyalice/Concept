load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ConceptSettingsUI",
    module_name = "ConceptSettingsUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/ConceptBadges",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/Display:Display",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/AccountContext:AccountContext",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//Swiftgram/ConceptSettings:ConceptSettings",
        "//Swiftgram/SGAppGroupIdentifier:SGAppGroupIdentifier",
        "//submodules/ConceptNotifications:ConceptNotifications",
        "//submodules/SettingsUI:SettingsUI",
        "//submodules/PasscodeUI:PasscodeUI",
        "//submodules/ItemListPeerActionItem:ItemListPeerActionItem",
        "//submodules/ItemListPeerItem:ItemListPeerItem",
        "//submodules/TelegramStringFormatting:TelegramStringFormatting",
        "//submodules/AccountUtils:AccountUtils",
        "//submodules/UndoUI:UndoUI",
        "//submodules/TelegramIntents:TelegramIntents",
        "//submodules/AvatarNode:AvatarNode",
    ],
    visibility = [
        "//visibility:public",
    ],
)
