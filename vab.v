module main

import os
import flag

import vxt
import semver

import java

import android
import android.sdk as asdk
import android.ndk as andk

const (
	exe_name	= os.file_name(os.executable())
	exe_dir		= os.base_dir(os.real_path(os.executable()))
)

const (
	default_app_name = 'V Default App'
	default_package_id = 'org.v.android.default.app'
)

const (
	min_supported_api_level = '21'
)

/* fn appendenv(name, value string) {
	os.setenv(name, os.getenv(name)+os.path_delimiter+value, true)
}*/

struct Options {
	// App essentials
	app_name		string
	package_id		string
	icon			string
	// Internals
	verbosity		int
	work_dir		string
	// Build and packaging
	version_code	int
	device_id		string
	keystore		string
	keystore_alias	string
	// Detected environment
	dump_env		bool
	dump_usage		bool
	list_ndks		bool
	list_apis		bool
	list_build_tools bool
mut:
	input			string
	output			string
	// Build and packaging
	v_flags			[]string
	lib_name		string
	assets_extra	[]string
	keystore_password string
	keystore_alias_password	string
	// Build specifics
	build_tools		string
	api_level		string
	ndk_version		string
}


fn main() {

	mut fp := flag.new_flag_parser(os.args)
	fp.application(exe_name)
	fp.version('0.1.0')
	fp.description('V Android Bootstrapper.\nCompile, package and deploy graphical V apps for Android.')
	fp.arguments_description('input')

	fp.skip_executable()

	verbosity := fp.int_opt('verbosity', `v`, 'Verbosity level 0-3') or { 0 }

	mut opt := Options {

		assets_extra: fp.string_multi('assets', `a`, 'Asset dir(s) to include in build')
		v_flags: fp.string_multi('flag', `f`, 'Additional flags for the V compiler')

		device_id: fp.string('device-id', `d`, '', 'Deploy to device ID')
		keystore: fp.string('keystore', 0, '', 'Use this keystore file to sign the package')
		keystore_alias: fp.string('keystore-alias', 0, '', 'Use this keystore alias from the keystore file to sign the package')

		dump_env: fp.bool('env', `e`, false, 'Dump the detected environment and exit')
		dump_usage: fp.bool('help', `h`, false, 'Show this help message and exit')

		app_name: fp.string('name', 0, default_app_name, 'Pretty app name')
		package_id: fp.string('package-id', 0, default_package_id, 'App package ID (e.g. "org.v.app")')
		icon: fp.string('icon', 0, '', 'App icon')
		version_code: fp.int('version-code', 0, 0, 'Build version code (android:versionCode)')

		output: fp.string('output', `o`, '', 'Path to output (dir/file)')

		verbosity: verbosity

		build_tools: fp.string('build-tools', 0, '', 'Version of build-tools to use (--list-build-tools)')
		api_level: fp.string('api', 0, '', 'Android API level to use (--list-apis)')

		ndk_version: fp.string('ndk-version', 0, '', 'Android NDK version to use (--list-ndks)')

		work_dir: os.join_path(os.temp_dir(), exe_name.replace(' ','_').to_lower())

		list_ndks:  fp.bool('list-ndks', 0, false, 'List available NDK versions')
		list_apis:  fp.bool('list-apis', 0, false, 'List available API levels')
		list_build_tools:  fp.bool('list-build-tools', 0, false, 'List available Build-tools versions')
	}

	additional_args := fp.finalize() or {
		eprintln(err)
		println(fp.usage())
		exit(1)
	}

	// Validate environment
	check_dependencies()

	resolve_options(mut opt)

	if opt.list_ndks {
		for ndk_v in andk.versions_available() {
			println(ndk_v)
		}
		exit(0)
	}

	if opt.list_apis {
		for api in asdk.apis_available() {
			println(api)
		}
		exit(0)
	}

	if opt.list_build_tools {
		for btv in asdk.build_tools_available() {
			println(btv)
		}
		exit(0)
	}

	if fp.args.len == 0 || opt.dump_usage {
		println(fp.usage())
		exit(1)
	}

	input := fp.args[fp.args.len-1]

	if additional_args.len > 1 {
		if additional_args[0] == 'install' {
			install_arg := additional_args[1]
			install_res := install(opt,install_arg)
			if install_res == 0 && opt.verbosity > 0 {
				println('Installed ${install_arg} successfully')
			}
			exit( install_res )
		}
	}
	if '-prod' in additional_args {
		opt.v_flags << '-prod'
	}
	if '-cg' in additional_args {
		opt.v_flags << '-cg'
	}

	if opt.dump_env {
		dump(opt)
		exit(0)
	}

	input_ext := os.file_ext(input)
	accepted_input_files := ['.v','.apk','.aab']

	if ! (os.is_dir(input) || input_ext in accepted_input_files) {
		println(fp.usage())
		eprintln('$exe_name requires input to be a V file, an APK, AAB or or V sources a directory')
		exit(1)
	}
	opt.input = input

	deploy_opt := android.DeployOptions {
		verbosity: opt.verbosity
		device_id: opt.device_id
		deploy_file: opt.output
	}

	if input_ext in accepted_input_files {
		if opt.device_id != '' {
			if ! android.deploy(deploy_opt) {
				eprintln('$exe_name deployment didn\'t succeed')
				exit(1)
			} else {
				if opt.verbosity > 0 {
					println('Deployed to ${opt.device_id} successfully')
				}
				exit(1)
			}
		}
	}

	comp_opt := android.CompileOptions {
		verbosity:		opt.verbosity
		v_flags:		opt.v_flags

		work_dir:		opt.work_dir
		input:			opt.input

		ndk_version:	opt.ndk_version
		lib_name:		opt.lib_name
		api_level:		opt.api_level
	}
	if ! android.compile(comp_opt) {
		eprintln('$exe_name compiling didn\'t succeed')
		exit(1)
	}

	// Keystore file
	mut keystore := opt.keystore
	if !os.is_file(keystore) {
		if keystore != '' {
			println('Couldn\'t locate "$keystore"')
		}
		eprintln('Falling back to default debug.keystore')
		keystore = ''
	}
	if keystore == '' {
		keystore = os.join_path(exe_dir,'debug.keystore')
	}
	pck_opt := android.PackageOptions {
		verbosity:					opt.verbosity
		work_dir:					opt.work_dir

		api_level:					opt.api_level
		build_tools:				opt.build_tools

		app_name:					opt.app_name
		lib_name:					opt.lib_name
		package_id:					opt.package_id
		icon:						opt.icon
		version_code:				opt.version_code

		v_flags:					opt.v_flags

		input:						opt.input
		assets_extra:				opt.assets_extra
		output_file:				opt.output
		keystore: 					keystore
		keystore_alias: 			opt.keystore_alias
		keystore_password:			opt.keystore_password
		keystore_alias_password:	opt.keystore_alias_password
		base_files:					os.join_path(exe_dir, 'platforms', 'android')
	}
	if ! android.package(pck_opt) {
		eprintln('Packaging didn\'t succeed')
		exit(1)
	}

	if opt.device_id != '' {

		if ! android.deploy(deploy_opt) {
			eprintln('Deployment didn\'t succeed')
			exit(1)
		} else {
			if opt.verbosity > 0 {
				println('Deployed to ${opt.device_id} successfully')
			}
		}
	} else {
		if opt.verbosity > 0 {
			println('Generated ${os.real_path(opt.output)}')
			println('Use `$exe_name --device-id <id> ${os.real_path(opt.output)}` to deploy package')
		}
	}
}

fn check_dependencies() {

	// Validate V install
	if vxt.vexe() == '' {
		eprintln('No V install could be detected')
		eprintln('Please install V from https://github.com/vlang/v')
		eprintln('or provide a valid path to V via VEXE env variable')
		exit(1)
	}

	// Validate Java requirements
	if ! java.jdk_found() {
		eprintln('No Java install(s) could be detected')
		eprintln('Please install Java 8 JDK or provide a valid path via JAVA_HOME')
		eprintln('(Currently Java 8 (1.8.x) is the only Java version supported by the Android SDK)')
		exit(1)
	}

	jdk_version := java.jdk_version()
	if jdk_version == '' {
		eprintln('No Java JDK install(s) could be detected')
		eprintln('Please install Java 8 JDK or provide a valid path via JAVA_HOME')
		eprintln('(Currently Java 8 (1.8.x) is the only Java version supported by the Android SDK)')
		exit(1)
	}

	jdk_semantic_version := semver.from(jdk_version) or { panic(err) }

	if ! jdk_semantic_version.satisfies('1.8.*') {
		// Some Android tools like `sdkmanager` currently only run with Java 8 JDK (1.8.x).
		// (Absolute mess, yes)
		eprintln('Java version ${jdk_version} is not supported')
		eprintln('Please install Java 8 JDK or provide a valid path via JAVA_HOME')
		eprintln('(Currently Java 8 (1.8.x) is the only Java version supported by the Android SDK)')
		exit(1)
	}

	// Validate Android SDK requirements
	if ! asdk.found() {
		eprintln('No Android SDK could be detected.')
		eprintln('Please provide a valid path via ANDROID_SDK_ROOT')
		eprintln('or run `$exe_name install sdk`')
		exit(1)
	}

	// Validate Android NDK requirements
	if ! andk.found() {
		eprintln('No Android NDK could be detected.')
		eprintln('Please provide a valid path via ANDROID_NDK_ROOT')
		eprintln('or run `$exe_name install ndk`')
		exit(1)
	}
}

fn resolve_options(mut opt Options) {

	// Validate API level
	mut api_level := asdk.default_api_level
	if opt.api_level != '' {
		if asdk.has_api(opt.api_level) {
			api_level = opt.api_level
		} else {
			// TODO Warnings
			eprintln('Android API level ${opt.api_level} is not available in SDK.')
			//eprintln('(It can be installed with `$exe_name install android-api-${opt.api_level}`)')
			eprintln('Falling back to default ${api_level}')
		}
	}
	if api_level == '' {
		eprintln('Android API level ${opt.api_level} is not available in SDK.')
		//eprintln('It can be installed with `$exe_name install android-api-${opt.api_level}`')
		exit(1)
	}
	if api_level.i16() < 20 {
		eprintln('Android API level ${api_level} is less than the recomended level (${min_supported_api_level}).')
		exit(1)
	}

	opt.api_level = api_level

	// Validate build-tools version
	mut build_tools_version := asdk.default_build_tools_version
	if opt.build_tools != '' {
		if asdk.has_build_tools(opt.build_tools) {
			build_tools_version = opt.build_tools
		} else {
			// TODO FIX Warnings and add install function
			eprintln('Android build-tools version ${opt.build_tools} is not available in SDK.')
			//eprintln('(It can be installed with `$exe_name install android-build-tools-${opt.build_tools}`)')
			eprintln('Falling back to default ${build_tools_version}')
		}
	}
	if build_tools_version == '' {
		eprintln('Android build-tools version ${opt.build_tools} is not available in SDK.')
		//eprintln('It can be installed with `$exe_name install android-api-${opt.api_level}`')
		exit(1)
	}

	opt.build_tools = build_tools_version

	// Validate ndk version
	mut ndk_version := andk.default_version()
	if opt.ndk_version != '' {
		if andk.has_version(opt.ndk_version) {
			ndk_version = opt.ndk_version
		} else {
			// TODO FIX Warnings and add install function
			eprintln('Android NDK version ${opt.ndk_version} is not available.')
			//eprintln('(It can be installed with `$exe_name install android-build-tools-${opt.build_tools}`)')
			eprintln('Falling back to default ${ndk_version}')
		}
	}
	if ndk_version == '' {
		eprintln('Android NDK version ${opt.ndk_version} is not available.')
		//eprintln('It can be installed with `$exe_name install android-api-${opt.api_level}`')
		exit(1)
	}

	opt.ndk_version = ndk_version

	// Output specific
	default_file_name := opt.app_name.replace(os.path_separator.str(),'').replace(' ','_').to_lower()

	mut output_file := ''
	if opt.output != '' {
		ext := os.file_ext(opt.output)
		if ext != '' {
			output_file = opt.output.all_before(ext)
		} else {
			output_file = os.join_path(opt.output.trim_right(os.path_separator),default_file_name)
		}
	} else {
		output_file = default_file_name
	}
	output_file += '.apk'
	opt.output = output_file

	// TODO can be supported when we can manipulate or generate AndroidManifest.xml + sources from code
	// Java package ids/names are integrated hard into the eco-system
	opt.lib_name = opt.app_name.replace(' ','_').to_lower()

	if os.getenv('KEYSTORE_PASSWORD') != '' {
		opt.keystore_password = os.getenv('KEYSTORE_PASSWORD')
	}
	if os.getenv('KEYSTORE_ALIAS_PASSWORD') != '' {
		opt.keystore_alias_password = os.getenv('KEYSTORE_ALIAS_PASSWORD')
	}
}

fn install(opt Options, component string) int {

	install_tools := fn (opt Options) {
		vab_cmd := [exe_name,'install','tools','-v',opt.verbosity.str()]
		res := os.exec(vab_cmd.join(' ')) or { os.Result{1,''} }
		if res.exit_code > 0 {
			eprintln('${vab_cmd[0]} failed with return code ${res.exit_code}')
			eprintln(res.output)
			exit(1)
		}
	}

	if component == 'tools' {
		android.setup(android.SetupOptions{.commandline_tools,opt.verbosity}) or {
			eprintln(err)
			exit(1)
		}
	} else if component == 'sdk' {
		tools_root := android.dependency_root(.commandline_tools)

		if tools_root == '' {
			install_tools(opt)
		}

		sdk_setup := android.SetupOptions{.sdk,opt.verbosity}
		android.setup(sdk_setup) or {
			eprintln(err)
			exit(1)
		}

	} else if component == 'ndk' {
		tools_root := android.dependency_root(.commandline_tools)

		if tools_root == '' {
			install_tools(opt)
		}

		ndk_setup := android.SetupOptions{.ndk,opt.verbosity}
		android.setup(ndk_setup) or {
			eprintln(err)
			exit(1)
		}

	} else {
		eprintln('$exe_name '+@FN+': Unknown component "$component"')
		return 1
	}
	return 0
}

fn dump(opt Options) {
	println('V')
	println('\tVersion ${vxt.version()}')
	println('\tPath ${vxt.home()}')
	if opt.v_flags.len > 0 {
		println('\tFlags ${opt.v_flags}')
	}
	println('Java')
	println('\tJDK')
	println('\t\tVersion ${java.jdk_version()}')
	println('\t\tPath ${java.jdk_root()}')
	println('Android')
	println('\tSDK')
	println('\t\tPath ${asdk.root()}')
	println('\tNDK')
	println('\t\tVersion ${opt.ndk_version}')
	println('\t\tPath ${andk.root()}')
	println('\tBuild')
	println('\t\tAPI ${opt.api_level}')
	println('\t\tBuild-tools ${opt.build_tools}')
	if opt.keystore != '' || opt.keystore_alias != '' {
		println('\tKeystore')
		println('\t\tFile ${opt.keystore}')
		println('\t\tAlias ${opt.keystore_alias}')
	}
	println('Product')
	println('\tName "${opt.app_name}"')
	println('\tPackage ${opt.package_id}')
	println('\tOutput ${opt.output}')
	println('')
}
