#!/usr/bin/env python3
"""
Generate MacNTFS.xcodeproj: the menu-bar app with the FSKit module embedded.

The project exists for code signing: Xcode's automatic signing registers the
App IDs, enables the FSKit Module capability and creates the provisioning
profiles. The C engine is still built by make, from a build phase.

Usage: scripts/gen-xcodeproj.py [TEAM_ID]
"""
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEAM = sys.argv[1] if len(sys.argv) > 1 else "NRZQU2K9AD"
APP_ID = "com.venky.macntfs"
EXT_ID = APP_ID + ".fsmodule"

APP_SOURCES = ["app/Sources/App.swift", "app/Sources/Disks.swift", "app/Sources/Mounter.swift"]
EXT_SOURCES = ["fskit/Sources/BlockDevice.swift", "fskit/Sources/Engine.swift",
               "fskit/Sources/FileSystem.swift", "fskit/Sources/Volume.swift"]
OTHER_FILES = ["app/Info.plist", "fskit/Info.plist", "fskit/NTFSModule.entitlements",
               "engine/include/mn.h"]


def oid(name):
    """Stable 24-hex-digit object id, so regenerating gives the same file."""
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


objects = []


def obj(key, isa, **fields):
    objects.append((oid(key), isa, fields))
    return oid(key)


def q(s):
    s = str(s)
    if s and all(c.isalnum() or c in "._/$" for c in s) and not s[0].isdigit():
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render(v, indent):
    pad = "\t" * indent
    if isinstance(v, dict):
        inner = "".join(f"{pad}\t{q(k)} = {render(x, indent + 1)};\n" for k, x in v.items())
        return "{\n" + inner + pad + "}"
    if isinstance(v, list):
        inner = "".join(f"{pad}\t{render(x, indent + 1)},\n" for x in v)
        return "(\n" + inner + pad + ")"
    return q(v)


def file_type(path):
    return {".swift": "sourcecode.swift", ".plist": "text.plist.xml", ".h": "sourcecode.c.h",
            ".entitlements": "text.plist.entitlements"}[os.path.splitext(path)[1]]


# File references and groups, mirroring the folders on disk.
groups = {}
for path in APP_SOURCES + EXT_SOURCES + OTHER_FILES:
    ref = obj("ref:" + path, "PBXFileReference", lastKnownFileType=file_type(path),
              path=os.path.basename(path), sourceTree="<group>")
    groups.setdefault(os.path.dirname(path), []).append(ref)


def group_tree(prefix):
    """Create PBXGroups for every directory under prefix; return child ids."""
    children = []
    subdirs = sorted({d[len(prefix):].lstrip("/").split("/")[0]
                      for d in groups if d.startswith(prefix) and d != prefix and d})
    for sub in subdirs:
        full = f"{prefix}/{sub}" if prefix else sub
        kids = group_tree(full) + groups.get(full, [])
        children.append(obj("group:" + full, "PBXGroup", children=kids, path=sub, sourceTree="<group>"))
    return children


app_product = obj("product:app", "PBXFileReference", explicitFileType="wrapper.application",
                  includeInIndex=0, path="MAC_NTFS.app", sourceTree="BUILT_PRODUCTS_DIR")
ext_product = obj("product:ext", "PBXFileReference", explicitFileType="wrapper.extensionkit-extension",
                  includeInIndex=0, path="NTFSModule.appex", sourceTree="BUILT_PRODUCTS_DIR")
products = obj("group:Products", "PBXGroup", children=[app_product, ext_product],
               name="Products", sourceTree="<group>")
main_group = obj("group:main", "PBXGroup", children=group_tree("") + [products], sourceTree="<group>")


def sources_phase(name, files):
    builds = [obj(f"build:{name}:{p}", "PBXBuildFile", fileRef=oid("ref:" + p)) for p in files]
    return obj("phase:sources:" + name, "PBXSourcesBuildPhase", buildActionMask=2147483647,
               files=builds, runOnlyForDeploymentPostprocessing=0)


def frameworks_phase(name):
    return obj("phase:frameworks:" + name, "PBXFrameworksBuildPhase", buildActionMask=2147483647,
               files=[], runOnlyForDeploymentPostprocessing=0)


engine_phase = obj("phase:engine", "PBXShellScriptBuildPhase", buildActionMask=2147483647,
                   files=[], inputPaths=[], name="Build C engine (make)",
                   outputPaths=["$(SRCROOT)/build/out/libmn.a"],
                   runOnlyForDeploymentPostprocessing=0, shellPath="/bin/sh",
                   shellScript='make -C "$SRCROOT" build/out/libmn.a\n',
                   alwaysOutOfDate=1)

embed_ext = obj("build:embed:ext", "PBXBuildFile", fileRef=ext_product,
                settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
embed_phase = obj("phase:embed", "PBXCopyFilesBuildPhase", buildActionMask=2147483647,
                  dstPath="$(EXTENSIONS_FOLDER_PATH)", dstSubfolderSpec=16, files=[embed_ext],
                  name="Embed ExtensionKit Extensions", runOnlyForDeploymentPostprocessing=0)

COMMON = {
    "CODE_SIGN_STYLE": "Automatic",
    "DEVELOPMENT_TEAM": TEAM,
    "MACOSX_DEPLOYMENT_TARGET": "26.0",
    "SWIFT_VERSION": "5.0",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "CURRENT_PROJECT_VERSION": "1",
    "MARKETING_VERSION": "0.1.0",
    # libntfs-3g is built by make for the host architecture only.
    "ARCHS": "$(NATIVE_ARCH_ACTUAL)",
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
}


def configs(name, settings):
    debug = obj(f"config:{name}:Debug", "XCBuildConfiguration", buildSettings=dict(settings), name="Debug")
    release = obj(f"config:{name}:Release", "XCBuildConfiguration", buildSettings=dict(settings), name="Release")
    return obj("configlist:" + name, "XCConfigurationList", buildConfigurations=[debug, release],
               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


ext_target = obj("target:ext", "PBXNativeTarget",
                 buildConfigurationList=configs("ext", {
                     **COMMON,
                     "PRODUCT_NAME": "NTFSModule",
                     "PRODUCT_MODULE_NAME": "NTFSModule",
                     "PRODUCT_BUNDLE_IDENTIFIER": EXT_ID,
                     "INFOPLIST_FILE": "fskit/Info.plist",
                     "CODE_SIGN_ENTITLEMENTS": "fskit/NTFSModule.entitlements",
                     "SWIFT_OBJC_BRIDGING_HEADER": "engine/include/mn.h",
                     "OTHER_LDFLAGS": ["$(SRCROOT)/build/out/libmn.a",
                                       "$(SRCROOT)/build/ntfs-3g/prefix/lib/libntfs-3g.a",
                                       "-framework", "CoreFoundation", "-framework", "FSKit"],
                     "SKIP_INSTALL": "YES",
                 }),
                 buildPhases=[engine_phase, sources_phase("ext", EXT_SOURCES), frameworks_phase("ext")],
                 buildRules=[], dependencies=[], name="NTFSModule", productName="NTFSModule",
                 productReference=ext_product,
                 productType="com.apple.product-type.extensionkit-extension")

proxy = obj("proxy:ext", "PBXContainerItemProxy", containerPortal=oid("project"), proxyType=1,
            remoteGlobalIDString=ext_target, remoteInfo="NTFSModule")
dependency = obj("dep:ext", "PBXTargetDependency", target=ext_target, targetProxy=proxy)

app_target = obj("target:app", "PBXNativeTarget",
                 buildConfigurationList=configs("app", {
                     **COMMON,
                     "PRODUCT_NAME": "MAC_NTFS",
                     "PRODUCT_MODULE_NAME": "MacNTFS",
                     "EXECUTABLE_NAME": "MacNTFS",
                     "PRODUCT_BUNDLE_IDENTIFIER": APP_ID,
                     "INFOPLIST_FILE": "app/Info.plist",
                     "OTHER_LDFLAGS": ["-framework", "DiskArbitration", "-framework", "FSKit"],
                 }),
                 buildPhases=[sources_phase("app", APP_SOURCES), frameworks_phase("app"), embed_phase],
                 buildRules=[], dependencies=[dependency], name="MacNTFS", productName="MAC_NTFS",
                 productReference=app_product, productType="com.apple.product-type.application")

project_configs = configs("project", {"SDKROOT": "macosx", "ALWAYS_SEARCH_USER_PATHS": "NO"})
objects.append((oid("project"), "PBXProject", {
    "attributes": {"BuildIndependentTargetsInParallel": 1, "LastSwiftUpdateCheck": 2650,
                   "LastUpgradeCheck": 2650,
                   "TargetAttributes": {app_target: {"CreatedOnToolsVersion": "26.5"},
                                        ext_target: {"CreatedOnToolsVersion": "26.5"}}},
    "buildConfigurationList": project_configs,
    "compatibilityVersion": "Xcode 14.0",
    "developmentRegion": "en",
    "hasScannedForEncodings": 0,
    "knownRegions": ["en", "Base"],
    "mainGroup": main_group,
    "productRefGroup": products,
    "projectDirPath": "",
    "projectRoot": "",
    "targets": [app_target, ext_target],
}))

# Write, grouped by isa as Xcode does.
out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};",
       "\tobjectVersion = 60;", "\tobjects = {"]
for isa in sorted({o[1] for o in objects}):
    out.append(f"\n/* Begin {isa} section */")
    for ident, kind, fields in sorted(o for o in objects if o[1] == isa):
        out.append(f"\t\t{ident} = {render({'isa': isa, **fields}, 2)};")
    out.append(f"/* End {isa} section */")
out += ["\t};", f"\trootObject = {oid('project')};", "}", ""]

proj = os.path.join(ROOT, "MacNTFS.xcodeproj")
os.makedirs(proj, exist_ok=True)
with open(os.path.join(proj, "project.pbxproj"), "w") as f:
    f.write("\n".join(out))
print(f"wrote {proj} (team {TEAM})")
