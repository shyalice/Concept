load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@rules_cc//cc:objc_library.bzl", "objc_library")

objc_library(
    name = "CloudDataSupport",
    module_name = "CloudDataSupport",
    enable_modules = True,
    srcs = ["Support/CloudDataSupport.m"],
    hdrs = ["PublicHeaders/CloudDataSupport/CloudDataSupport.h"],
    includes = ["PublicHeaders"],
    sdk_frameworks = ["Foundation", "CloudKit"],
)

swift_library(
    name = "CloudData",
    module_name = "CloudData",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":CloudDataSupport",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/EncryptionProvider:EncryptionProvider",
    ],
    visibility = [
        "//visibility:public",
    ],
)
