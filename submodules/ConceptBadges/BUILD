load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ConceptBadges",
    module_name = "ConceptBadges",
    srcs = glob(["Sources/**/*.swift"]),
    deps = ["//submodules/Display", "//submodules/TelegramCore"],
    copts = ["-warnings-as-errors"],
    visibility = ["//visibility:public"],
)
