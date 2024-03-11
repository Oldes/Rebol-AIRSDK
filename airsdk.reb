Rebol [
	name:  airsdk
	type:  module
	title: "AIR SDK build utilities"
	needs: 3.16.0
	exports: [air-task]
	author: @Oldes
	version: 0.1.0
	date: 11-Mar-2024
	purpose: {To automate common AIRSDK compilation tasks in a cross-platform way using a config file.}
]

quit-on-error?: true
windows?: system/platform = 'Windows

set-env 'AIR_NOANDROIDFLAIR "true" ;- not using `air.` application id prefix!
unless AIR_SDK: get-env 'AIR_SDK [
	set-env 'AIR_SDK AIR_SDK: pick ["c:\Dev\SDKs\AIRSDK\" "~/SDKS/AIRSDK/"] Windows?
]
AIR_SDK: to-rebol-file AIR_SDK

to-logic: func[value][to logic! find [#(true) true on] :value]

;----------------------------------------------------------------------------------;
;-- Rebol/AIRSDK Scheme                                                          --;
;----------------------------------------------------------------------------------;

sys/make-scheme [
	name: 'airsdk
	title: "AIRSDK build commands"
	spec: make system/standard/port-spec-head [
		config:  none
		AIR_SDK: none 
		temp:   %temp/
		build:  %Build/
	]
	actor: [
		open: func [
			port [port!]
			/local file spec conn
		][
			try/with [
				port/spec/config: load port/spec/target
				port/spec/AIR_SDK: to-rebol-file any [
					port/spec/AIR_SDK
					port/spec/config/AIR_SDK
					get-env 'AIR_SDK
				]
			] :on-error
			port
		]

		open?: func[port][
			not none? port/spec/config
		]

		write: func[
			port [port!]
			commands
			/local key val data state config path values blk
		][
			unless open? port [open port]
			unless block? commands [commands: to block! commands]
			;?? commands
			spec: port/spec
			config: :spec/config
			parse commands [ any [
				['build-swf | 'make-swf] (
					try/with [build-swf :spec] :on-error
				)
				| ['build-aab | 'make-aab] (
					try/with [build-aab :spec] :on-error
				)
				| ['build-android-project | 'make-android-project] (
					try/with [build-android-project :spec] :on-error
				)
				| ['test | 'local-test] (
					try/with [local-test :spec] :on-error
				)
				| 'config set data: [block! | get-word! | get-path!] (
					unless block? data [data: get data]
					print [as-green "Config modified with: " as-yellow mold data]
					parse data [any [
						set key: set-word! set val: skip (
							extend config key val
						)
						|
						set key: set-path! set val: skip (
							path: join 'spec/config key
							either block? val [
								blk: get path
								foreach [key val] val [
									extend get :path key val
								]
							][
								key: take/last path
								extend get :path key val
							]
						)

					]]
				)
				| 'make-air-config (
					try/with [make-air-config :config/flex-config] :on-error
				)
				| 'extract-apk (
					try/with [extract-apk :spec] :on-error
				)
				| copy val: skip (
					on-error ajoin ["Unknown AIRSDK port command: " as-red :val]
				)
			]]
		]
	]
]


;----------------------------------------------------------------------------------;
;-- Build commands                                                               --;
;----------------------------------------------------------------------------------;

export
air-task: func[
	"Evaluates code in an AIRSDK context"
	label [string!] code [block!] /local tmp
][
	print-label label
	if tmp: get-env 'AIR_SDK [AIR_SDK: to-rebol-file tmp]
	try/with bind code self :on-error
]

make-air-config: closure/with [
	"Generates air-config.xml file used in SWF compilation"
	config [block! object! map!]
][
	append clear ind LF
	append clear out <?xml version="1.0" encoding="utf-8"?>
	emit-config 'flex-config config
	write %swf-config.xml out
] context [
	out: make string! 1000
	ind: make string! 8

	emit-config: func[key data][
		append out ajoin [ind #"<" key ">"]
		append ind SP
		foreach [k v] data [
			if k = 'configs [
				foreach [k v] v [
					if string? v [v: ajoin [{"} v {"}]]
					append out ajoin [ind {<define append="true"><name>CONFIG::} k {</name><value>} v </value></define>]
				]
				continue
			]
			switch type?/word v [
				block! [
					either set-word? first v [
						emit-config k v
					][
						append out ajoin [ind #"<" k { append="true">}]
						append ind SP
						foreach f v [
							append out ajoin [ind "<path-element>" to-local-file f </path-element>]
						]
						take/last ind
						append out ajoin [ind "</" k #">"]
					]
					continue
				]
				pair!  [v: ajoin [<width> to integer! v/x </width><height> to integer! v/y </height>]]
				issue! [v: mold v]
			]

			append out ajoin [ind #"<" k #">" v "</" k #">"]
		]
		take/last ind
		append out ajoin [ind "</" key ">"]
	]
]

build-swf: function[
	"Builds SWF from ActionScript sources using `mxmlc-cli` tool"
	spec [block! object! map!] "Application configuration"
][
	print-label "Building SWF file"
	config: make map! spec/config
	make-air-config :config/flex-config
	delete-file swf: rejoin [any [config/root %./] %main.swf]
	unless zero? call [
		"java -Dsun.io.useCanonCaches=false -Xms32m -Xmx512m"
		" -Dflexlib="    to-local-file config/AIR_SDK/frameworks
		" -jar "         to-local-file config/AIR_SDK/lib/mxmlc-cli.jar
		" -load-config=" to-local-file config/AIR_SDK/frameworks/air-config.xml
		" -load-config+=swf-config.xml +configname=air"
		" -advanced-telemetry=" to-logic :config/advanced-telemetry
		" -o " to-local-file swf
	][
		print as-purple "SWF compilation failed!"
		quit
	]
	delete %swf-config.xml
	swf
]

build-aab: function [spec] [
	print-label "Building AAB"
	config: make map! spec/config
	make-dir/deep spec/build
	aab: rejoin [spec/build config/name %.aab]
	delete-file :aab
	;call ["echo No air. prefix? %AIR_NOANDROIDFLAIR%"]
	call [
		"java -jar " to-local-file config/AIR_SDK/lib/adt.jar
		" -package -target aab"
		;" -storetype pkcs12 -keystore cert.p12 -storepass fd "
		;" -storetype jks -keystore certificate.keystore -alias 1 -storepass qwerty "
		to-adt-cert-flags   :config  ;== signing options
		SP to-local-file     :aab    ;== output file
		to-adt-file-content :config  ;== manifest file + content
		if file? config/extdir [join " -extdir " to-local-file config/extdir]
		" -platformsdk " to-local-file config/ANDROID_SDK
	]
	unless exists? :aab [fail "Building AAB failed!"]
	:aab
]

build-android-project: function [spec] [
	print-label "Building AAB"
	config: make map! spec/config
	call [
		"java -jar " to-local-file config/AIR_SDK/lib/adt.jar
		" -package -target android-studio ./_project_/"
		to-adt-file-content :config  ;== manifest file + content
		if file? config/extdir [join " -extdir " to-local-file config/extdir]
		" -platformsdk " to-local-file config/ANDROID_SDK
	]
]



build-ane: function[
	"Builds AIR Native Extension (ANE)"
	args [block!]
][
	id: select args 'id
	swc-file: any [select args 'swc  rejoin [%build/ id %.swc]]
	ane-file: any [select args 'ane  rejoin [%build/ id %.ane]]
	aar-file: any [select args 'aar  rejoin [%build/ id %.aar]]

	AIR_SDK: to-rebol-file any [
		select args 'AIR_SDK
		get-env 'AIR_SDK
	]

	swc: decode 'zip :swc-file
	lib: second select swc %library.swf
	cat: second select swc %catalog.xml

	aar: decode 'zip :aar-file
	jar: second select aar %classes.jar

	res: select args 'resources

	adt-args: compose [
		-package
		-target ane (:ane-file) %temp/extension.xml
		-swc (:swc-file)
	]
	ext: rejoin [{<extension xmlns="http://ns.adobe.com/air/extension/22.0">
	<id>} :id {</id>
	<versionNumber>1</versionNumber>
	<platforms>}
	]

	delete-dir %temp/
	foreach platform args/platforms [
		make-dir/deep dir: dirize join %temp/assets/platform/ platform
		write dir/library.swf lib
		write rejoin [dir args/initializer %.jar] jar

		dir-res: rejoin [dir %res- id %/]


		if res [ xcopy res dir ]

		foreach [path data] aar [
			parse path [%res/ [end | copy path: to end (
				either dir? path [
					make-dir/deep dir-res/:path
				][	write dir-res/:path data/2 ]
			)]]
		]
		packagedResources: clear ""
		if exists? dir/platform.xml [
			tmp: read/string dir/platform.xml
			parse tmp [thru <packagedDependencies> copy packagedDependencies: to </packagedDependencies>]
			parse tmp [thru <packagedResources> copy packagedResources: to </packagedResources>]
		]
		if exists? dir-res [
			append packagedResources ajoin [
				{^/^-<packagedResource>}
				{^/^-^-<packageName>} id {</packageName>}
				{^/^-^-<folderName>res-} id {</folderName>} 
				{^/^-</packagedResource>}
			]
		]
		write dir/platform.xml ajoin [
			{<platform xmlns="http://ns.adobe.com/air/extension/22.0">}
			{^/<packagedDependencies>} packagedDependencies
			{^/</packagedDependencies>}
			{^/<packagedResources>} packagedResources
			{^/</packagedResources>}
			{^/</platform>}
		]

		append adt-args compose [
			-platform (to word! platform) -C (dir) .
		;	-platformoptions (dir/platform-options.xml)
		]
		append ext rejoin [{
	  <platform name="} platform {">
		<applicationDeployment>
		  <nativeLibrary>} args/initializer {.jar</nativeLibrary>
		  <initializer>} id #"." args/initializer {</initializer>
		</applicationDeployment>
	  </platform>}
		]
	]

	append ext {^/^-</platforms>^/</extension>}

	write %temp/extension.xml ext
	if 0 <> res: call-java AIR_SDK/lib/adt.jar adt-args [
		fail reform ["ADT call failed with result code:" res]
	]
]

;make-certificate: func[file][
;	call [
;		"java -jar " to-local-file AIR_SDK/lib/adt.jar
;		" -certificate"
;		" -cn Amanita Design"
;		{ -o "Amanita Design s r. o."}
;                    -validityPeriod 20
;                    -ou AU 2048-RSA
;                    YOUR_CERTIFICATE.p12
;                    PASSWORD
;]
;

start-apk: function[id][
	call reform ["adb shell monkey -p" id "-v" 1]
]



build-apk: does [
	print-label "Building APK"
	delete-file build-dir/:APK
	call [
		"java -jar " to-local-file AIR_SDK/lib/adt.jar
		" -package -target apk-captive-runtime -arch armv8"
		" -storetype pkcs12 -keystore cert.p12 -storepass fd "
		to-local-file build-dir/:APK
		" application-v33.xml main.swf icons/* assetpack1 assetpack2 assetpack3"
		" -extdir ane/"
	]
]

to-adt-cert-flags: function [config][
	cert: make map! config/certificate
	ajoin [
		" -storetype " cert/storetype
		" -keystore "  to-local-file cert/keystore
		if value: cert/alias     [join " -alias " :value]
		if value: cert/storepass [join " -storepass " :value]
	]
]
to-bundle-cert-flags: function [config][
	;" --ks=certificate.keystore --ks-key-alias=1 --ks-pass=pass:qwerty"
	cert: make map! config/certificate
	ajoin [
		" --ks=" to-local-file :cert/keystore
		if value: cert/alias     [join " --ks-key-alias=" :value]
		if value: cert/storepass [join " --ks-pass=pass:" :value]
	]
]
to-adt-file-content: function [config][
	out: ajoin [
		SP to-local-file any [config/manifest %application.xml]
	]
	dir: any [config/root %""]
	if block? config/content [
		foreach file config/content [
			append append out SP to-local-file dir/:file 
		]
	]
	if block? config/assetPacks [
		foreach file config/assetPacks [
			append append out SP to-local-file file 
		]
	]
	out
]



build-test-apks: function[spec][
	config: make map! spec/config
	aab:  rejoin [spec/build config/name %.aab]
	test: rejoin [spec/build config/name %-test.apks]
	unless exists? aab [
		print as-purple "AAB file not found... trying to build it!"
		build-aab spec
	]
	print-label "Extracting AAB for local test"
	delete-file :test
	call [
		"java -jar " to-local-file config/BUNDLETOOL
		" build-apks --bundle=" to-local-file :aab
		to-bundle-cert-flags :config
		" --output=" to-local-file :test
		" --local-testing"
	]
	unless exists? :test [fail "Building test APKS failed!"]
	test
]

extract-aab: function[spec /uni][
	print-label "Extracting AAB"
	? spec
	aab:  rejoin [spec/build spec/config/name %.aab]
	probe apks: rejoin [spec/build spec/config/name %.apks]
	delete-file apks
	call [
		"java -jar " to-local-file spec/config/BUNDLETOOL
		" build-apks --bundle=" to-local-file :aab
		to-bundle-cert-flags :spec/config
		" --output=" to-local-file :apks
		either uni [" --mode=universal"][]
	]
	apks
]
extract-apk: function[spec][
	data: decode 'zip read apks: extract-aab/uni spec
	apk: rejoin [spec/build spec/config/name %-universal.apk]
	write :apk second select data %universal.apk
	delete apks
	apk
]

p12-to-keystore: function[src [file!] jks [file!]][
	call [
		"keytool -importkeystore -srcstoretype pkcs12"
		" -srckeystore "  to-local-file src
		" -destkeystore " to-local-file jks
	]
]


android-app-id: function/with [
	"Replaces all unsupported chars with underscore"
	id [any-string!]
][
	;; Android app id allowes only these chars: a-zA-Z0-9_ and dot between segments
	;; AIR is not so strict and when making a build for Android, replaces other chars with _
	parse id: copy id [any [some ch_appid | #"." | change skip #"_"]]
	id
][
	ch_appid: make bitset! #{000000000000FFC07FFFFFE17FFFFFE0} ;= a-zA-Z0-9_
]

local-test: function[spec][
	test: build-test-apks :spec
	config: make map! spec/config
	app-id: android-app-id :config/appid
	print-label "Uninstalling first"
	call form-cmd %adb [uninstall :app-id]
	print-label "Installing test apk"
	call-java config/BUNDLETOOL ["install-apks --apks " :test]
	print-label "Start test apk"
	start-apk :app-id
]

make-icon-res: function[res [file!] src [file! image!]][
	unless image? src [src: load src]

	foreach [size dir][
		192x192 %mipmap-xxxhdpi-v4
		144x144 %mipmap-xxhdpi-v4
		96x96   %mipmap-xhdpi-v4
		48x48   %mipmap-mdpi-v4
		48x48   %mipmap-ldpi-v4
		72x72   %mipmap-hdpi-v4
	][
		save res/:dir/icon.png resize :src :size
	]
]


ane-dependencies: function[
	"Downloads Java dependencies required for AIR native extension"
	output       [file!]  "Output directory where the resources are collected"
	dependencies [block!] "Required dependencies"
][
	maven: import 'maven
	resources: maven/get-dependencies dependencies
	print-horizontal-line
	resources: sort/skip to block! resources 2
	make-dir/deep output

	packagedDependencies: copy ""
	packagedResources:    copy ""
	packagedDependencies: copy ""
	dependencies:         copy ""
	groups-with-res:      copy []

	foreach [id pom] resources [
		file: pom/local-file
		local: maven/cache-dir/:file
		unless exists? local [
			print rejoin [as-purple "*** Dependency resources not found: " as-red local]
			unless ask "continue?" [quit]
			continue
		]
		dep-group:    replace/all copy any [pom/groupId pom/parent/groupId] #"/" #"."
		dep-artifact: pom/artifactId
		dep-version:  pom/version
		type: any [pom/packaging "jar"]
		
		repend dependencies [file LF]

		name: ajoin [dep-group #"_" dep-artifact #"-" dep-version]
		jar:  ajoin [name %.jar]
		if type = "aar" [
			call ["jar xfv " to-local-file local " res classes.jar"]

			if all [exists? %res/ not empty? read %res/] [
				res: ajoin ["res_" name]
				append groups-with-res dep-group
				append groups-with-res res
				move-dir %res output/:res
			]
			if exists? %classes.jar [
				move-file %classes.jar output/:jar
				append packagedDependencies rejoin [
					{^/^-^-<packagedDependency>} jar {</packagedDependency>}
				]
			]
			continue
		]
		if type = "jar" [
			copy-file local output/:jar
			append packagedDependencies rejoin [
				{^/^-^-<packagedDependency>} jar {</packagedDependency>}
			]
			continue
		]
	]
	print-horizontal-line
	print as-blue "Collected dependencies:"
	print dependencies

	write output/dependencies.txt dependencies

	foreach [gID res] groups-with-res [
		append packagedResources rejoin [{
	   <packagedResource>
	      <packageName>} gID {</packageName> 
	        <folderName>} res {</folderName> 
	   </packagedResource>}
		]
	]

	manifest: rejoin [{<platform xmlns="http://ns.adobe.com/air/extension/22.0"> 
	  <packagedDependencies>} packagedDependencies {
	  </packagedDependencies> 
	  <packagedResources>}  packagedResources {
	  </packagedResources>
	</platform>}]

	write output/platform.xml manifest
]



;----------------------------------------------------------------------------------;
;-- Utilities, aliases and shortcuts                                             --;
;----------------------------------------------------------------------------------;

call: func[cmd][
	if block? cmd [ cmd: rejoin cmd ]
	print ["CALL: " as-yellow cmd]
	lib/call/shell/wait/console cmd
]
eval: func[bin [file!] args [block!]][
	unless zero? call form-cmd bin args [on-error "CALL failed!"]
]

quit: func[/return value] [if quit-on-error? [lib/quit/return value]]
fail: func[msg][cause-error 'user 'message msg]

on-error: func[err][
	print as-purple err
	quit
]


print-label: func[txt][
	print-horizontal-line
	print as-green txt
]
start-task: func[txt][print-label txt]

delete-file: func[file][
	if exists? file [
		print [as-green "Deleting old build:" as-yellow file]
		try/with [delete file] :on-error
	]
]

copy-file: func[src [file!] dst [file!]][
	print [as-green "Copying" src as-green "to" dst]
	if dir? src [ fail "Copying directories not implemented!"]
	if dir? dst [ append dst second split-path src]
	try/with [
		write/binary dst read/binary src
	] :on-error
]

move-file: func[src [file!] dst [file!]][
	print [as-green "Moving" src as-green "to" dst]
	if dir? src [ fail "Moving directories not implemented!"]
	if dir? dst [ append dst second split-path src]
	try/with [
		also write/binary dst read/binary src delete src
	] :on-error
]

move-dir: func[src [file!] dst [file!]][
	either windows? [
		call form-cmd %MOVE [:src :dst]
	][	call form-cmd %mv [:src :dst]]
]

xcopy: func[src [file!] dst [file!]][
	either windows? [
		call form-cmd %xcopy ["/S /Y" :src :dst]
	][	call form-cmd %cp ["-f -R" :src :dst] ]
]

form-cmd: func[bin args /local cmd][
	cmd: make string! 100
	if file? bin [bin: to-local-file bin]
	append append cmd bin SP
	either block? args [
		foreach arg args [
			if any [get-word? :arg get-path? :arg] [arg: get :arg]
			if file? :arg [arg: to-local-file arg]
			append append cmd :arg SP
		]
	][	append cmd args ]
]

compc: function[args [block!]][
	out: select args '-output
	unless out [
		print [as-purple "Missing" as-red "-output" as-purple "argument!"]
		if quit-on-error? [lib/quit]
		exit
	]
	delete-file out
	call form-cmd AIR_SDK/bin/acompc args
	unless exists? out [
		print as-purple "Compilation failed!"
		quit
	]
	out
]


call-java: function[jar args][
	call form-cmd %java append reduce ['-jar to-local-file jar] args
]