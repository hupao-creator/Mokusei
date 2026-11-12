"""Build only independent collectors and controls; never build the target app."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

SOURCE = Path(__file__).resolve().parent


def build(directory):
    directory.mkdir(parents=True, exist_ok=True)
    source_files = sorted([Path(__file__), *SOURCE.glob('native/*'), *SOURCE.glob('conformance/*.swift'),
                           *SOURCE.glob('conformance/*.c'), *SOURCE.glob('hitch/*.swift')])
    toolchain = subprocess.check_output(['xcodebuild', '-version'], text=True)
    digest = hashlib.sha256(toolchain.encode())
    for path in source_files:
        digest.update(path.name.encode()); digest.update(path.read_bytes())
    identity = digest.hexdigest()
    stamp = directory / 'build.json'
    if stamp.exists() and json.loads(stamp.read_text()).get('sourceHash') == identity:
        return directory
    subprocess.run(['xcrun', 'clang', '-O2', '-c', str(SOURCE/'native/Support.c'), '-o', str(directory/'Support.o')], check=True)
    subprocess.run(['xcrun', 'clang', '-O2', '-I', str(SOURCE/'native'), str(SOURCE/'conformance/CPUClock.c'),
                    str(directory/'Support.o'), '-o', str(directory/'cpu-clock-check')], check=True)
    cpu_clock = json.loads(subprocess.check_output([str(directory/'cpu-clock-check')], text=True, timeout=15))
    (directory/'cpu-clock-check.json').write_text(json.dumps(cpu_clock, indent=2) + '\n')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O', '-parse-as-library', '-import-objc-header',
                    str(SOURCE/'native/Support.h'), str(SOURCE/'native/Collector.swift'), str(directory/'Support.o'),
                    '-o', str(directory/'collector')], check=True)
    app = directory/'Control.app'
    (app/'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.mokusei.external-benchmark.control',
        'CFBundleName':'Benchmark Control','CFBundleExecutable':'Control','CFBundlePackageType':'APPL',
        'NSHighResolutionCapable':True,'LSMinimumSystemVersion':'26.0'}))
    subprocess.run(['xcrun','swiftc','-swift-version','5','-O','-parse-as-library',str(SOURCE/'conformance/Control.swift'),
                    '-o',str(app/'Contents/MacOS/Control')],check=True)
    subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
    make_hitch_project(directory)
    with (directory/'hitch-build.log').open('w') as log:
        process=subprocess.run(['xcodebuild','-project',str(directory/'Hitch.xcodeproj'),'-scheme','Hitch',
            '-configuration','Release','-destination','platform=macOS','-derivedDataPath',str(directory/'HitchBuild'),
            'CODE_SIGN_IDENTITY=-','build-for-testing'],stdout=log,stderr=subprocess.STDOUT)
    if process.returncode:
        raise RuntimeError('independent hitch build failed; see '+str(directory/'hitch-build.log'))
    stamp.write_text(json.dumps({'sourceHash':identity,'toolchain':toolchain,'cpuClockCheck':cpu_clock},indent=2))
    return directory


def make_hitch_project(directory):
    objects={}
    def obj(key_name, isa, **values):
        key=hashlib.sha256(key_name.encode()).hexdigest()[:24].upper()
        objects[key]={'isa':isa,**values}
        return key
    source=obj('source','PBXFileReference',lastKnownFileType='sourcecode.swift',path=str(SOURCE/'hitch/HitchTests.swift'),sourceTree='<absolute>')
    product=obj('product','PBXFileReference',explicitFileType='wrapper.cfbundle',path='HitchTests.xctest',sourceTree='BUILT_PRODUCTS_DIR')
    file=obj('file','PBXBuildFile',fileRef=source)
    phase=obj('sources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=[file],runOnlyForDeploymentPostprocessing=0)
    frameworks=obj('frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)
    products=obj('products','PBXGroup',children=[product],name='Products',sourceTree='<group>')
    group=obj('group','PBXGroup',children=[source,products],sourceTree='<group>')
    settings={'SDKROOT':'macosx','MACOSX_DEPLOYMENT_TARGET':'26.0','SWIFT_VERSION':'5.0',
        'PRODUCT_BUNDLE_IDENTIFIER':'com.mokusei.external-benchmark.HitchTests','PRODUCT_NAME':'$(TARGET_NAME)',
        'GENERATE_INFOPLIST_FILE':'YES','CODE_SIGN_IDENTITY':'-','CODE_SIGN_STYLE':'Manual',
        'ENABLE_APP_SANDBOX':'NO','ENABLE_USER_SCRIPT_SANDBOXING':'NO','ALWAYS_SEARCH_USER_PATHS':'NO',
        'SWIFT_OPTIMIZATION_LEVEL':'-O','ENABLE_HARDENED_RUNTIME':'NO','SUPPORTED_PLATFORMS':'macosx',
        'LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/../Frameworks','@loader_path/../Frameworks']}
    config=obj('config','XCBuildConfiguration',buildSettings=settings,name='Release')
    configs=obj('configs','XCConfigurationList',buildConfigurations=[config],defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
    target=obj('target','PBXNativeTarget',buildConfigurationList=configs,buildPhases=[phase,frameworks],buildRules=[],dependencies=[],
        name='HitchTests',productName='HitchTests',productReference=product,productType='com.apple.product-type.bundle.ui-testing')
    project=obj('project','PBXProject',attributes={'LastUpgradeCheck':'2650'},buildConfigurationList=configs,compatibilityVersion='Xcode 14.0',
        developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','Base'],mainGroup=group,productRefGroup=products,
        projectDirPath='',projectRoot='',targets=[target])
    folder=directory/'Hitch.xcodeproj';folder.mkdir(exist_ok=True)
    (folder/'project.pbxproj').write_bytes(plistlib.dumps({'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':project}))
    schemes=folder/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
    reference=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="HitchTests.xctest" BlueprintName="HitchTests" ReferencedContainer="container:Hitch.xcodeproj"/>'
    (schemes/'Hitch.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2650" version="1.3"><BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Release" selectedDebuggerIdentifier="" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO" parallelizable="NO">{reference}</TestableReference></Testables></TestAction></Scheme>''')
