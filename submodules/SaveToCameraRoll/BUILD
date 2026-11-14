load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SaveToCameraRoll",
    module_name = "SaveToCameraRoll",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/Display:Display",
        "//submodules/AccountContext:AccountContext",
        "//submodules/DeviceAccess:DeviceAccess",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/TelegramUI/Components/AlertComponent:AlertComponent",
        "//submodules/ComponentFlow:ComponentFlow",
        "//Swiftgram/SGStrings:SGStrings",
        "//submodules/LegacyComponents:LegacyComponents",
    ],
    visibility = [
        "//visibility:public",
    ],
)
