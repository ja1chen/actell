#!/usr/bin/env python3
"""Generate the checked-in project with Python stdlib; no XcodeGen install needed."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re

ROOT = Path(__file__).resolve().parents[1]
objects = {}


def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def add(identifier, isa, **fields):
    key = uid(identifier)
    objects[key] = dict(isa=isa, **fields)
    return key


def serialize_project(project, project_name):
    """Match Xcode's sectioned OpenStep layout while retaining stable object IDs."""
    graph = project["objects"]
    phases = {}
    owners = {}
    for obj in graph.values():
        if obj["isa"].endswith("BuildPhase"):
            label = obj.get("name", obj["isa"].removeprefix("PBX").removesuffix("BuildPhase"))
            for member in obj.get("files", []):
                phases[member] = label
        if "buildConfigurationList" in obj:
            owners[obj["buildConfigurationList"]] = (obj["isa"], obj.get("name", project_name))

    def comment(identifier):
        obj = graph[identifier]
        kind = obj["isa"]
        if kind == "PBXBuildFile":
            referenced = obj.get("fileRef", obj.get("productRef"))
            return comment(referenced) + " in " + phases[identifier]
        if kind == "PBXProject":
            return "Project object"
        if kind == "XCConfigurationList":
            owner_kind, name = owners[identifier]
            return f'Build configuration list for {owner_kind} "{name}"'
        if kind == "XCLocalSwiftPackageReference":
            return f'{kind} "{obj["relativePath"]}"'
        if kind == "XCRemoteSwiftPackageReference":
            name = obj["repositoryURL"].rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")
            return f'{kind} "{name}"'
        if kind == "XCSwiftPackageProductDependency":
            return obj["productName"]
        if kind.endswith("BuildPhase"):
            return obj.get("name", kind.removeprefix("PBX").removesuffix("BuildPhase"))
        if kind in ("PBXContainerItemProxy", "PBXTargetDependency"):
            return kind
        return obj.get("name", obj.get("path", ""))

    def atom(value, field=None, reference=True):
        if isinstance(value, int):
            return str(value)
        unquoted = re.fullmatch(r"[A-Za-z0-9_/][A-Za-z0-9_./]*", value) and "//" not in value
        text = value if unquoted else json.dumps(value, ensure_ascii=False)
        if reference and value in graph and field != "remoteGlobalIDString":
            label = comment(value).replace("*/", "* /").replace("\n", " ").replace("\r", " ")
            if label:
                text += " /* " + label + " */"
        return text

    def encode(value, indent=0, inline=False, field=None):
        if isinstance(value, dict):
            keys = sorted(value, key=lambda key: (key != "isa", key))
            if inline:
                entries = (atom(key, reference=False) + " = " + encode(value[key], inline=True, field=key) + "; " for key in keys)
                return "{" + "".join(entries) + "}"
            entries = (
                "\t" * (indent + 1) + atom(key, reference=False) + " = "
                + encode(value[key], indent + 1, field=key) + ";\n"
                for key in keys
            )
            return "{\n" + "".join(entries) + "\t" * indent + "}"
        if isinstance(value, list):
            if inline:
                return "(" + "".join(encode(item, inline=True, field=field) + ", " for item in value) + ")"
            entries = ("\t" * (indent + 1) + encode(item, indent + 1, field=field) + ",\n" for item in value)
            return "(\n" + "".join(entries) + "\t" * indent + ")"
        return atom(value, field=field)

    sections = {}
    for identifier, obj in graph.items():
        sections.setdefault(obj["isa"], []).append(identifier)
    lines = ["// !$*UTF8*$!\n{\n"]
    for key in sorted(project):
        if key != "objects":
            lines.append("\t" + atom(key, reference=False) + " = " + encode(project[key], 1, field=key) + ";\n")
            continue
        lines.append("\tobjects = {\n")
        for kind, identifiers in sorted(sections.items()):
            lines.append(f"\n/* Begin {kind} section */\n")
            for identifier in sorted(identifiers):
                body = encode(graph[identifier], 2, inline=kind in ("PBXBuildFile", "PBXFileReference"))
                lines.append("\t\t" + atom(identifier) + " = " + body + ";\n")
            lines.append(f"/* End {kind} section */\n")
        lines.append("\t};\n")
    lines.append("}\n")
    return "".join(lines)


def configs(name, settings):
    ids = []
    for configuration in ("Debug", "Release"):
        s = dict(settings)
        s.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if configuration == "Debug" else "-O",
                 # Match SPM's Debug architecture for a concrete simulator.
                 # A generic destination still builds all supported architectures.
                 ONLY_ACTIVE_ARCH="YES" if configuration == "Debug" else "NO")
        if configuration == "Debug":
            s.update(ENABLE_TESTABILITY="YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG $(inherited)")
        ids.append(add(name + configuration, "XCBuildConfiguration", name=configuration, buildSettings=s))
    return add(name + "Configurations", "XCConfigurationList", buildConfigurations=ids, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


def generate(*, ignore_env=False):
    environment = {} if ignore_env else os.environ
    prefix = environment.get("ACTELL_BUNDLE_ID_PREFIX", "").strip()
    prefix = prefix.removesuffix(".") if prefix else "com.ja1chen.PhoneAgent"
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*", prefix):
        raise ValueError("ACTELL_BUNDLE_ID_PREFIX must contain dot-separated letters, digits or hyphens")
    team = environment.get("ACTELL_DEVELOPMENT_TEAM", "").strip()
    packages = [
        add("SwiftAgentKit", "XCLocalSwiftPackageReference", relativePath="Vendor/SwiftAgentKit"),
        add("ProviderKit", "XCLocalSwiftPackageReference", relativePath="ProviderKit"),
        add("MarkdownUI", "XCRemoteSwiftPackageReference", repositoryURL="https://github.com/gonzalezreal/swift-markdown-ui.git",
            requirement=dict(kind="exactVersion", version="2.4.1")),
        add("SwiftCertificates", "XCRemoteSwiftPackageReference", repositoryURL="https://github.com/apple/swift-certificates.git",
            requirement=dict(kind="exactVersion", version="1.10.0")),
    ]
    targets, groups, products = [], [], []
    for name, extension, product_type, bundle_suffix in [
        ("PhoneAgent", "app", "application", ""),
        ("PhoneAgentTests", "xctest", "bundle.unit-test", "Tests"),
        ("PhoneAgentUITests", "xctest", "bundle.ui-testing", "UITests"),
        ("PhoneAgentLiveActivity", "appex", "app-extension", ".LiveActivity"),
    ]:
        sources, children = [], []
        paths = list((ROOT / name).rglob("*.swift"))
        if name in ("PhoneAgent", "PhoneAgentLiveActivity"):
            paths += list((ROOT / "Shared").rglob("*.swift"))
        for path in sorted(paths):
            relative = Path(os.path.relpath(path, ROOT)).as_posix()
            ref = add((name if relative.startswith("Shared/") else "") + relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="SOURCE_ROOT")
            children.append(ref)
            sources.append(add((name if relative.startswith("Shared/") else "") + relative + "Build", "PBXBuildFile", fileRef=ref))
        if name == "PhoneAgent":
            for path in sorted((ROOT.parent / "coredevice/swift/Sources/CoreDeviceBackend").glob("*.swift")):
                relative = "../coredevice/swift/Sources/CoreDeviceBackend/" + path.name
                ref = add(relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="SOURCE_ROOT")
                children.append(ref)
                sources.append(add(relative + "Build", "PBXBuildFile", fileRef=ref))
        resources = []
        for path in sorted((ROOT / name).glob("*.xcassets")):
            relative = Path(os.path.relpath(path, ROOT)).as_posix()
            ref = add(relative, "PBXFileReference", lastKnownFileType="folder.assetcatalog", path=relative, sourceTree="SOURCE_ROOT")
            children.append(ref)
            resources.append(add(relative + "Build", "PBXBuildFile", fileRef=ref))
        catalogs = list((ROOT / name).rglob("*.xcstrings"))
        if name in ("PhoneAgent", "PhoneAgentLiveActivity"):
            catalogs += list((ROOT / "Shared").rglob("*.xcstrings"))
        for path in sorted(catalogs):
            relative = Path(os.path.relpath(path, ROOT)).as_posix()
            ref = add((name if relative.startswith("Shared/") else "") + relative, "PBXFileReference", lastKnownFileType="text.json.xcstrings", path=relative, sourceTree="SOURCE_ROOT")
            children.append(ref)
            resources.append(add((name if relative.startswith("Shared/") else "") + relative + "Build", "PBXBuildFile", fileRef=ref))
        if name == "PhoneAgent":
            ref = add("PrivacyManifest", "PBXFileReference", lastKnownFileType="text.xml", path="PhoneAgent/PrivacyInfo.xcprivacy", sourceTree="SOURCE_ROOT")
            children.append(ref)
            resources.append(add("PrivacyBuild", "PBXBuildFile", fileRef=ref))
            ref = add("Licenses", "PBXFileReference", lastKnownFileType="folder", path="Licenses", sourceTree="SOURCE_ROOT")
            children.append(ref)
            resources.append(add("LicensesBuild", "PBXBuildFile", fileRef=ref))
            ref = add("BuiltinSkills", "PBXFileReference", lastKnownFileType="folder", path="PhoneAgent/BuiltinSkills", sourceTree="SOURCE_ROOT")
            children.append(ref)
            resources.append(add("BuiltinSkillsBuild", "PBXBuildFile", fileRef=ref))
        group = add(name + "Group", "PBXGroup", name=name, children=children, sourceTree="<group>")
        groups.append(group)
        file_type = {"app": "wrapper.application", "appex": "wrapper.app-extension", "xctest": "wrapper.cfbundle"}[extension]
        product = add(name + "Product", "PBXFileReference", explicitFileType=file_type,
                      includeInIndex=0, path=name + "." + extension, sourceTree="BUILT_PRODUCTS_DIR")
        products.append(product)
        package_products, frameworks = [], []
        linked_products = [] if name in ("PhoneAgentUITests", "PhoneAgentLiveActivity") else [("SwiftAgentKit", packages[0]), ("ProviderCore", packages[1]), ("OpenAIAdapter", packages[1])]
        # Hosted tests resolve X509 through the app's BUNDLE_LOADER. Linking its
        # product into both promotes transitive Crypto to an empty dynamic
        # framework on Xcode 27, which fails before the app can compile.
        if name == "PhoneAgent":
            linked_products.append(("X509", packages[3]))
        for product_name, package in linked_products:
            dependency = add(name + product_name, "XCSwiftPackageProductDependency", package=package, productName=product_name)
            package_products.append(dependency)
            frameworks.append(add(name + product_name + "Build", "PBXBuildFile", productRef=dependency))
        if name == "PhoneAgent":
            dependency = add(name + "MarkdownUI", "XCSwiftPackageProductDependency", package=packages[2], productName="MarkdownUI")
            package_products.append(dependency)
            frameworks.append(add(name + "MarkdownUIBuild", "PBXBuildFile", productRef=dependency))
        phases = [add(name + "Sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=sources, runOnlyForDeploymentPostprocessing=0),
                  add(name + "Frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=frameworks, runOnlyForDeploymentPostprocessing=0),
                  add(name + "Resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=resources, runOnlyForDeploymentPostprocessing=0)]
        settings = dict(PRODUCT_NAME="$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER=prefix + bundle_suffix,
                        CODE_SIGN_STYLE="Automatic", DEVELOPMENT_TEAM=team, GENERATE_INFOPLIST_FILE="YES",
                        TARGETED_DEVICE_FAMILY="1,2", SUPPORTED_PLATFORMS="iphoneos iphonesimulator",
                        SUPPORTS_MACCATALYST="NO", MARKETING_VERSION="0.1.0", CURRENT_PROJECT_VERSION="1",
                        LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks"])
        dependencies = []
        if name == "PhoneAgent":
            settings.update(ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon", INFOPLIST_FILE="PhoneAgent/Info.plist", INFOPLIST_KEY_CFBundleDisplayName="Actell",
                            INFOPLIST_KEY_NSSupportsLiveActivities="YES",
                            INFOPLIST_KEY_NSLocalNetworkUsageDescription="Allow paired phone-control devices and Muse Gadget to connect with Actell on the local network.",
                            INFOPLIST_KEY_NSLocationWhenInUseUsageDescription="When you enable location for background execution, the app uses location services to help your task continue when you switch apps. Your location is never saved or uploaded. This uses more battery and shows the location indicator. You can decline or turn it off at any time.",
                            INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription="Save the images you choose to your photo library.",
                            INFOPLIST_KEY_UIApplicationSceneManifest_Generation="YES",
                            INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents="YES",
                            INFOPLIST_KEY_UILaunchScreen_Generation="YES")
            settings.update(ARCHS="arm64", ENABLE_USER_SCRIPT_SANDBOXING="NO",
                            HEADER_SEARCH_PATHS=["$(inherited)", "$(SRCROOT)/../coredevice/swift/Sources/CCoreDeviceBackend/include"],
                            OTHER_LDFLAGS=["$(inherited)", "-lcoredevice_backend", "-framework", "Security", "-framework", "SystemConfiguration"],
                            **{"LIBRARY_SEARCH_PATHS[sdk=iphoneos*]": ["$(inherited)", "$(SRCROOT)/../.build/coredevice-rust/aarch64-apple-ios/release"],
                               "LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]": ["$(inherited)", "$(SRCROOT)/../.build/coredevice-rust/aarch64-apple-ios-sim/release"]})
            phases.insert(0, add("CoreDeviceBackendBuild", "PBXShellScriptBuildPhase", buildActionMask=2147483647,
                                 files=[], inputPaths=[], outputPaths=[], runOnlyForDeploymentPostprocessing=0,
                                 alwaysOutOfDate=1, name="Build CoreDevice backend", shellPath="/bin/bash",
                                 shellScript='case "$PLATFORM_NAME" in\n iphoneos) mode=device ;;\n iphonesimulator) mode=simulator ;;\n *) exit 1 ;;\nesac\nbash "$SRCROOT/../tools/build_coredevice_rust.sh" "$mode"\n'))
            widget = "PhoneAgentLiveActivity"
            embedded = add("EmbedLiveActivityBuild", "PBXBuildFile", fileRef=uid(widget + "Product"), settings=dict(ATTRIBUTES=["RemoveHeadersOnCopy"]))
            phases.append(add("EmbedLiveActivity", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="", dstSubfolderSpec=13,
                              files=[embedded], name="Embed App Extensions", runOnlyForDeploymentPostprocessing=0))
            proxy = add("LiveActivityProxy", "PBXContainerItemProxy", containerPortal=uid("Project"), proxyType=1, remoteGlobalIDString=uid(widget + "Target"), remoteInfo=widget)
            dependencies.append(add("LiveActivityDependency", "PBXTargetDependency", target=uid(widget + "Target"), targetProxy=proxy))
        elif name == "PhoneAgentLiveActivity":
            settings.update(INFOPLIST_FILE="PhoneAgentLiveActivity/Info.plist",
                            INFOPLIST_KEY_CFBundleDisplayName="Actell", APPLICATION_EXTENSION_API_ONLY="YES", SKIP_INSTALL="YES",
                            LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"])
        else:
            if name == "PhoneAgentUITests":
                settings.update(TEST_TARGET_NAME="PhoneAgent")
            else:
                settings.update(TEST_HOST="$(BUILT_PRODUCTS_DIR)/PhoneAgent.app/PhoneAgent", BUNDLE_LOADER="$(TEST_HOST)",
                                HEADER_SEARCH_PATHS=["$(inherited)", "$(SRCROOT)/../coredevice/swift/Sources/CCoreDeviceBackend/include"])
            proxy = add(name + "AppProxy", "PBXContainerItemProxy", containerPortal=uid("Project"), proxyType=1, remoteGlobalIDString=uid("PhoneAgentTarget"), remoteInfo="PhoneAgent")
            dependencies.append(add(name + "AppDependency", "PBXTargetDependency", target=uid("PhoneAgentTarget"), targetProxy=proxy))
        targets.append(add(name + "Target", "PBXNativeTarget", name=name, productName=name, productReference=product,
                           productType="com.apple.product-type." + product_type, buildConfigurationList=configs(name, settings),
                           buildPhases=phases, buildRules=[], dependencies=dependencies, packageProductDependencies=package_products))
    products_group = add("Products", "PBXGroup", name="Products", children=products, sourceTree="<group>")
    main_group = add("RootGroup", "PBXGroup", children=groups + [products_group], sourceTree="<group>")
    common = dict(APP_DISPLAY_NAME="Actell", SDKROOT="iphoneos", IPHONEOS_DEPLOYMENT_TARGET="27.0", SWIFT_VERSION="5.0", SWIFT_STRICT_CONCURRENCY="complete", SWIFT_EMIT_LOC_STRINGS="YES",
                  CLANG_ENABLE_MODULES="YES", CLANG_ENABLE_OBJC_ARC="YES", GCC_C_LANGUAGE_STANDARD="gnu17")
    project = add("Project", "PBXProject", attributes=dict(LastUpgradeCheck="2700", BuildIndependentTargetsInParallel="YES"),
                  buildConfigurationList=configs("Project", common), compatibilityVersion="Xcode 14.0", developmentRegion="en",
                  hasScannedForEncodings=0, knownRegions=["en", "zh-Hans", "Base"], mainGroup=main_group, productRefGroup=products_group,
                  projectDirPath="", projectRoot="", targets=targets, packageReferences=packages)
    path = ROOT / "PhoneAgent.xcodeproj"
    path.mkdir(exist_ok=True)
    (path / "project.pbxproj").write_text(serialize_project(dict(archiveVersion=1, classes={}, objectVersion=60, objects=objects, rootObject=project), path.stem))
    workspace = path / "project.xcworkspace"
    workspace.mkdir(exist_ok=True)
    (workspace / "contents.xcworkspacedata").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n')
    schemes = path / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    def reference(name, extension):
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(name + "Target")}" BuildableName="{name}.{extension}" BlueprintName="{name}" ReferencedContainer="container:PhoneAgent.xcodeproj"/>'
    app, tests, ui_tests = reference("PhoneAgent", "app"), reference("PhoneAgentTests", "xctest"), reference("PhoneAgentUITests", "xctest")
    (schemes / "PhoneAgent.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><Testables><TestableReference skipped="NO">{tests}</TestableReference><TestableReference skipped="NO">{ui_tests}</TestableReference></Testables><EnvironmentVariables><EnvironmentVariable key="PHONEAGENT_ISOLATED_TESTS" value="1" isEnabled="YES"/></EnvironmentVariables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
    print(path)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-d", "--defaults", action="store_true",
                        help="Ignore environment overrides and generate the project with default settings.")
    args = parser.parse_args(argv)
    generate(ignore_env=args.defaults)


if __name__ == "__main__":
    main()
