#!/usr/bin/env python3
"""Generate the checked-in project with Python stdlib; no XcodeGen install needed."""
from pathlib import Path
import hashlib
import json
import os

ROOT = Path(__file__).resolve().parents[1]
objects = {}


def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def add(identifier, isa, **fields):
    key = uid(identifier)
    objects[key] = dict(isa=isa, **fields)
    return key


def encode(value, indent=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (indent + 1) + encode(k) + " = " + encode(v, indent + 1) + ";\n" for k, v in value.items()) + "\t" * indent + "}"
    if isinstance(value, list):
        return "(" + ", ".join(encode(v, indent) for v in value) + ("," if value else "") + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(value, ensure_ascii=False)


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


def generate():
    packages = [
        add("SwiftAgentKit", "XCLocalSwiftPackageReference", relativePath="Vendor/SwiftAgentKit"),
        add("ProviderKit", "XCLocalSwiftPackageReference", relativePath="ProviderKit"),
        add("MarkdownUI", "XCRemoteSwiftPackageReference", repositoryURL="https://github.com/gonzalezreal/swift-markdown-ui.git",
            requirement=dict(kind="exactVersion", version="2.4.1")),
        add("SwiftCertificates", "XCRemoteSwiftPackageReference", repositoryURL="https://github.com/apple/swift-certificates.git",
            requirement=dict(kind="exactVersion", version="1.10.0")),
    ]
    targets, groups, products = [], [], []
    for name, extension, product_type in [("PhoneAgent", "app", "application"), ("PhoneAgentTests", "xctest", "bundle.unit-test"), ("PhoneAgentUITests", "xctest", "bundle.ui-testing"), ("PhoneAgentLiveActivity", "appex", "app-extension")]:
        sources, children = [], []
        paths = list((ROOT / name).rglob("*.swift"))
        if os.environ.get("INCLUDE_ARCHIVED_TESTS") == "1" and name in ("PhoneAgentTests", "PhoneAgentUITests"):
            paths += list((ROOT.parent / "archives/tests" / name).glob("*.swift"))
        if name in ("PhoneAgent", "PhoneAgentLiveActivity"):
            paths += list((ROOT / "Shared").rglob("*.swift"))
        for path in sorted(paths):
            relative = Path(os.path.relpath(path, ROOT)).as_posix()
            ref = add((name if relative.startswith("Shared/") else "") + relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="SOURCE_ROOT")
            children.append(ref)
            sources.append(add((name if relative.startswith("Shared/") else "") + relative + "Build", "PBXBuildFile", fileRef=ref))
        if name == "PhoneAgent":
            for path in sorted((ROOT.parent / "ncm-dev/PhoneAgentNCM/Sources/PhoneAgentNCM").glob("*.swift")):
                relative = "../ncm-dev/PhoneAgentNCM/Sources/PhoneAgentNCM/" + path.name
                ref = add(relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="SOURCE_ROOT")
                children.append(ref)
                sources.append(add(relative + "Build", "PBXBuildFile", fileRef=ref))
        resources = []
        for path in sorted((ROOT / name).glob("*.xcassets")):
            relative = Path(os.path.relpath(path, ROOT)).as_posix()
            ref = add(relative, "PBXFileReference", lastKnownFileType="folder.assetcatalog", path=relative, sourceTree="SOURCE_ROOT")
            children.append(ref)
            resources.append(add(relative + "Build", "PBXBuildFile", fileRef=ref))
        for path in sorted((ROOT / name).rglob("*.xcstrings")):
            relative = Path(os.path.relpath(path, ROOT)).as_posix()
            ref = add(relative, "PBXFileReference", lastKnownFileType="text.json.xcstrings", path=relative, sourceTree="SOURCE_ROOT")
            children.append(ref)
            resources.append(add(relative + "Build", "PBXBuildFile", fileRef=ref))
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
        product = add(name + "Product", "PBXFileReference", explicitFileType="wrapper.application" if extension == "app" else "wrapper.cfbundle",
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
        settings = dict(PRODUCT_NAME="$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER="com.ja1chen." + name,
                        CODE_SIGN_STYLE="Automatic", DEVELOPMENT_TEAM="", GENERATE_INFOPLIST_FILE="YES",
                        TARGETED_DEVICE_FAMILY="1,2", SUPPORTED_PLATFORMS="iphoneos iphonesimulator",
                        SUPPORTS_MACCATALYST="NO", MARKETING_VERSION="0.1.0", CURRENT_PROJECT_VERSION="1",
                        LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks"])
        dependencies = []
        if name == "PhoneAgent":
            settings.update(ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon", INFOPLIST_FILE="PhoneAgent/Info.plist", INFOPLIST_KEY_CFBundleDisplayName="$(APP_DISPLAY_NAME)",
                            INFOPLIST_KEY_NSSupportsLiveActivities="YES",
                            INFOPLIST_KEY_NSLocalNetworkUsageDescription="Allow explicitly authorized phone-control devices and Muse clients to connect with Actell on the local network.",
                            INFOPLIST_KEY_UIApplicationSceneManifest_Generation="YES",
                            INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents="YES",
                            INFOPLIST_KEY_UILaunchScreen_Generation="YES")
            settings.update(ARCHS="arm64", ENABLE_USER_SCRIPT_SANDBOXING="NO",
                            HEADER_SEARCH_PATHS=["$(inherited)", "$(SRCROOT)/../ncm-dev/PhoneAgentNCM/Sources/CNCMBackend/include"],
                            OTHER_LDFLAGS=["$(inherited)", "-lphoneagent_ncm_backend", "-framework", "Security", "-framework", "SystemConfiguration"],
                            **{"LIBRARY_SEARCH_PATHS[sdk=iphoneos*]": ["$(inherited)", "$(SRCROOT)/../.build/ncm-rust/aarch64-apple-ios/release"],
                               "LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]": ["$(inherited)", "$(SRCROOT)/../.build/ncm-rust/aarch64-apple-ios-sim/release"]})
            phases.insert(0, add("NCMBackendBuild", "PBXShellScriptBuildPhase", buildActionMask=2147483647,
                                 files=[], inputPaths=[], outputPaths=[], runOnlyForDeploymentPostprocessing=0,
                                 alwaysOutOfDate=1, name="Build NCM backend", shellPath="/bin/bash",
                                 shellScript='case "$PLATFORM_NAME" in\n iphoneos) mode=device ;;\n iphonesimulator) mode=simulator ;;\n *) exit 1 ;;\nesac\nbash "$SRCROOT/../tools/build_ncm_rust.sh" "$mode"\n'))
            widget = "PhoneAgentLiveActivity"
            embedded = add("EmbedLiveActivityBuild", "PBXBuildFile", fileRef=uid(widget + "Product"), settings=dict(ATTRIBUTES=["RemoveHeadersOnCopy"]))
            phases.append(add("EmbedLiveActivity", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="", dstSubfolderSpec=13,
                              files=[embedded], name="Embed App Extensions", runOnlyForDeploymentPostprocessing=0))
            proxy = add("LiveActivityProxy", "PBXContainerItemProxy", containerPortal=uid("Project"), proxyType=1, remoteGlobalIDString=uid(widget + "Target"), remoteInfo=widget)
            dependencies.append(add("LiveActivityDependency", "PBXTargetDependency", target=uid(widget + "Target"), targetProxy=proxy))
        elif name == "PhoneAgentLiveActivity":
            settings.update(PRODUCT_BUNDLE_IDENTIFIER="com.ja1chen.PhoneAgent.LiveActivity", INFOPLIST_FILE="PhoneAgentLiveActivity/Info.plist",
                            INFOPLIST_KEY_CFBundleDisplayName="$(APP_DISPLAY_NAME)", APPLICATION_EXTENSION_API_ONLY="YES", SKIP_INSTALL="YES",
                            LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"])
        else:
            if name == "PhoneAgentUITests":
                settings.update(TEST_TARGET_NAME="PhoneAgent")
            else:
                settings.update(TEST_HOST="$(BUILT_PRODUCTS_DIR)/PhoneAgent.app/PhoneAgent", BUNDLE_LOADER="$(TEST_HOST)",
                                HEADER_SEARCH_PATHS=["$(inherited)", "$(SRCROOT)/../ncm-dev/PhoneAgentNCM/Sources/CNCMBackend/include"])
            proxy = add(name + "AppProxy", "PBXContainerItemProxy", containerPortal=uid("Project"), proxyType=1, remoteGlobalIDString=uid("PhoneAgentTarget"), remoteInfo="PhoneAgent")
            dependencies.append(add(name + "AppDependency", "PBXTargetDependency", target=uid("PhoneAgentTarget"), targetProxy=proxy))
        targets.append(add(name + "Target", "PBXNativeTarget", name=name, productName=name, productReference=product,
                           productType="com.apple.product-type." + product_type, buildConfigurationList=configs(name, settings),
                           buildPhases=phases, buildRules=[], dependencies=dependencies, packageProductDependencies=package_products))
    products_group = add("Products", "PBXGroup", name="Products", children=products, sourceTree="<group>")
    main_group = add("RootGroup", "PBXGroup", children=groups + [products_group], sourceTree="<group>")
    common = dict(APP_DISPLAY_NAME="执言", SDKROOT="iphoneos", IPHONEOS_DEPLOYMENT_TARGET="27.0", SWIFT_VERSION="5.0", SWIFT_STRICT_CONCURRENCY="complete",
                  CLANG_ENABLE_MODULES="YES", CLANG_ENABLE_OBJC_ARC="YES", GCC_C_LANGUAGE_STANDARD="gnu17")
    project = add("Project", "PBXProject", attributes=dict(LastUpgradeCheck="2700", BuildIndependentTargetsInParallel="YES"),
                  buildConfigurationList=configs("Project", common), compatibilityVersion="Xcode 14.0", developmentRegion="en",
                  knownRegions=["en", "zh-Hans", "Base"], mainGroup=main_group, productRefGroup=products_group,
                  projectDirPath="", projectRoot="", targets=targets, packageReferences=packages)
    path = ROOT / "PhoneAgent.xcodeproj"
    path.mkdir(exist_ok=True)
    (path / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project)) + "\n")
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


if __name__ == "__main__":
    generate()
