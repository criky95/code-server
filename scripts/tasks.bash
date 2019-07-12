#!/bin/bash
set -euo pipefail

function log() {
	local message="${1}" ; shift
	local level="${1:-info}"
	if [[ "${level}" == "error" ]] ; then
		>&2 echo "${message}"
	else
		echo "${message}"
	fi
}

function exit-if-ci() {
	if [[ -n "${ci}" ]] ; then
		log "Pre-built VS Code ${vscodeVersion}-${target}-${arch} is incorrectly built" "error"
		exit 1
	fi
}

# Copy code-server into VS Code along with its dependencies.
function copy-server() {
	log "Applying patch"
	cd "${vscodeSourcePath}"
	git reset --hard
	git clean -fd
	git apply "${rootPath}/scripts/vscode.patch"

	local serverPath="${vscodeSourcePath}/src/vs/server"
	rm -rf "${serverPath}"
	mkdir -p "${serverPath}"

	log "Copying code-server code"

	cp -r "${rootPath}/src" "${serverPath}"
	cp -r "${rootPath}/typings" "${serverPath}"
	cp "${rootPath}/main.js" "${serverPath}"
	cp "${rootPath}/package.json" "${serverPath}"
	cp "${rootPath}/yarn.lock" "${serverPath}"

	if [[ -d "${rootPath}/node_modules" ]] ; then
		log "Copying code-server build dependencies"
		cp -r "${rootPath}/node_modules" "${serverPath}"
	else
		log "Installing code-server build dependencies"
		cd "${serverPath}"
		# Ignore scripts to avoid also installing VS Code dependencies which has
		# already been done.
		yarn --ignore-scripts
		rm -r node_modules/@types/node # I keep getting type conflicts
	fi

	# TODO: Duplicate identifier issue. There must be a better way to fix this.
	if [[ "${target}" == "darwin" ]] ; then
		rm "${serverPath}/node_modules/fsevents/node_modules/safe-buffer/index.d.ts"
	fi
}

# Prepend the nbin shim which enables finding files within the binary.
function prepend-loader() {
	local filePath="${codeServerBuildPath}/${1}" ; shift
	cat "${rootPath}/scripts/nbin-shim.js" "${filePath}" > "${filePath}.temp"
	mv "${filePath}.temp" "${filePath}"
	# Using : as the delimiter so the escaping here is easier to read.
	# ${parameter/pattern/string}, so the pattern is /: (if the pattern starts
	# with / it matches all instances) and the string is \\: (results in \:).
	if [[ "${target}" == "darwin" ]] ; then
		sed -i "" -e "s:{{ROOT_PATH}}:${codeServerBuildPath//:/\\:}:g" "${filePath}"
	else
		sed -i "s:{{ROOT_PATH}}:${codeServerBuildPath//:/\\:}:g" "${filePath}"
	fi
}

# Copy code-server into VS Code then build it.
function build-code-server() {
	copy-server

	# TODO: look into making it do the full minified build for just our code
	# (basically just want to skip extensions, target our server code, and get
	# the same type of build you get with the vscode-linux-x64-min task).
	# Something like: yarn gulp "vscode-server-${target}-${arch}-min"
	log "Building code-server"
	yarn gulp compile-client

	rm -rf "${codeServerBuildPath}"
	mkdir -p "${codeServerBuildPath}"

	local json="{\"codeServerVersion\": \"${codeServerVersion}\"}"

	cp -r "${vscodeBuildPath}/resources/app/extensions" "${codeServerBuildPath}"
	node "${rootPath}/scripts/merge.js" "${vscodeBuildPath}/resources/app/package.json" "${rootPath}/scripts/package.json" "${codeServerBuildPath}/package.json" "${json}"
	node "${rootPath}/scripts/merge.js" "${vscodeBuildPath}/resources/app/product.json" "${rootPath}/scripts/product.json" "${codeServerBuildPath}/product.json"
	cp -r "${vscodeSourcePath}/out" "${codeServerBuildPath}"
	rm -rf "${codeServerBuildPath}/out/vs/server/typings"

	# Rebuild to make sure the native modules work since at the moment all the
	# pre-built packages are from one Linux system. This means you must build on
	# the target system.
	log "Installing remote dependencies"
	cd "${vscodeSourcePath}/remote"
	if [[ "${target}" != "linux" ]] ; then
		yarn --production --force
	fi
	cp -r "${vscodeSourcePath}/remote/node_modules" "${codeServerBuildPath}"

	# Only keep the production dependencies.
	cd "${codeServerBuildPath}/out/vs/server"
	yarn --production --ignore-scripts

	prepend-loader "out/vs/server/main.js"
	prepend-loader "out/bootstrap-fork.js"

	log "Final build: ${codeServerBuildPath}"
}

# Build VS Code if it hasn't already been built. If we're in the CI and it's
# not fully built, error and exit.
function build-vscode() {
	if [[ ! -d "${vscodeSourcePath}" ]] ; then
		exit-if-ci
		log "${vscodeSourceName} does not exist, cloning"
		git clone https://github.com/microsoft/vscode --quiet \
			--branch "${vscodeVersion}" --single-branch --depth=1 \
			"${vscodeSourcePath}"
	else
		log "${vscodeSourceName} already exists, skipping clone"
	fi

	cd "${vscodeSourcePath}"

	if [[ ! -d "${vscodeSourcePath}/node_modules" ]] ; then
		exit-if-ci
		log "Installing VS Code dependencies"
		# Not entirely sure why but there seem to be problems with native modules
		# so rebuild them.
		yarn --force

		# Keep just what we need to keep the pre-built archive smaller.
		rm -rf "${vscodeSourcePath}/test"
	else
		log "${vscodeSourceName}/node_modules already exists, skipping install"
	fi

	if [[ ! -d "${vscodeBuildPath}" ]] ; then
		exit-if-ci
		log "${vscodeBuildName} does not exist, building"
		local builtPath="${buildPath}/VSCode-${target}-${arch}"
		rm -rf "${builtPath}"
		yarn gulp "vscode-${target}-${arch}-min" --max-old-space-size=32384
		mkdir -p "${vscodeBuildPath}/resources/app"
		# Copy just what we need to keep the pre-built archive smaller.
		mv "${builtPath}/resources/app/extensions" "${vscodeBuildPath}/resources/app"
		mv "${builtPath}/resources/app/"*.json "${vscodeBuildPath}/resources/app"
		rm -rf "${builtPath}"
	else
		log "${vscodeBuildName} already exists, skipping build"
	fi
}

# Download VS Code with either curl or wget depending on which is available.
function download-vscode() {
	cd "${buildPath}"
	if command -v wget &> /dev/null ; then
		log "Attempting to download ${tarName} with wget"
		wget "${vsSourceUrl}" --quiet --output-document "${tarName}"
	else
		log "Attempting to download ${tarName} with curl"
		curl "${vsSourceUrl}" --silent --fail --output "${tarName}"
	fi
}

# Download pre-built VS Code if necessary. Build if there is no available
# download but not when in the CI. The pre-built package basically just
# provides us the dependencies and extensions so we don't have to install and
# build them respectively which takes a long time.
function prepare-vscode() {
	if [[ ! -d "${vscodeBuildPath}" || ! -d "${vscodeSourcePath}" ]] ; then
		mkdir -p "${buildPath}"
		# TODO: for now everything uses the Linux build and we rebuild the modules.
		# This means you must build on the target system.
		local tarName="vstar-${vscodeVersion}-${target}-${arch}.tar.gz"
		local linuxTarName="vstar-${vscodeVersion}-linux-${arch}.tar.gz"
		local linuxVscodeBuildName="vscode-${vscodeVersion}-linux-${arch}-built"
		local vsSourceUrl="https://codesrv-ci.cdr.sh/${linuxTarName}"
		if download-vscode ; then
			cd "${buildPath}"
			rm -rf "${vscodeBuildPath}"
			tar -xzf "${tarName}"
			rm "${tarName}"
			if [[ "${target}" != "linux" ]] ; then
				mv "${linuxVscodeBuildName}" "${vscodeBuildName}"
			fi
		elif [[ -n "${ci}" ]] ; then
			log "Pre-built VS Code ${vscodeVersion}-${target}-${arch} does not exist" "error"
			exit 1
		else
			log "${tarName} does not exist, building"
			build-vscode
			return
		fi
	else
		log "VS Code is already downloaded or built"
	fi

	log "Ensuring VS Code is fully built"
	build-vscode
}

function build-task() {
	prepare-vscode
	build-code-server
}

function vstar-task() {
	local archivePath="${releasePath}/vstar-${vscodeVersion}-${target}-${arch}.tar.gz"
	rm -f "${archivePath}"
	mkdir -p "${releasePath}"
	tar -C "${buildPath}" -czf "${archivePath}" "${vscodeSourceName}" "${vscodeBuildName}"
	log "Archive: ${archivePath}"
}

function package-task() {
	local archivePath="${releasePath}/${binaryName}"
	rm -rf "${archivePath}"
	mkdir -p "${archivePath}"

	cp "${buildPath}/${binaryName}" "${archivePath}/code-server"
	cp "${rootPath}/README.md" "${archivePath}"
	cp "${vscodeSourcePath}/LICENSE.txt" "${archivePath}"
	cp "${vscodeSourcePath}/ThirdPartyNotices.txt" "${archivePath}"

	cd "${releasePath}"
	if [[ "${target}" == "darwin" ]] ; then
		zip -r "${binaryName}.zip" "${binaryName}"
		log "Archive: ${archivePath}.zip"
	else
		tar -czf "${binaryName}.tar.gz" "${binaryName}"
		log "Archive: ${archivePath}.tar.gz"
	fi
}

# Package built code into a binary.
function binary-task() {
	# I had trouble getting VS Code to build with the @coder/nbin dependency due
	# to the types it installs (tons of conflicts), so for now it's a global
	# dependency.
	cd "${rootPath}"
	npm link @coder/nbin
	node "${rootPath}/scripts/nbin.js" "${target}" "${arch}" "${codeServerBuildPath}"
	rm node_modules/@coder/nbin
	mv "${codeServerBuildPath}/code-server" "${buildPath}/${binaryName}"
	log "Binary: ${buildPath}/${binaryName}"
}

# Check if it looks like we are inside VS Code.
function in-vscode () {
	log "Checking if we are inside VS Code"
	local dir="${1}" ; shift

	local maybeVscode
	local dirName
	maybeVscode="$(realpath "${dir}/../../..")"
	dirName="$(basename "${maybeVscode}")"

	if [[ "${dirName}" != "vscode" ]] ; then
		return 1
	fi
	if [[ ! -f "${maybeVscode}/package.json" ]] ; then
		return 1
	fi
	if ! grep '"name": "code-oss-dev"' "${maybeVscode}/package.json" --quiet ; then
		return 1
	fi

	return 0
}

function ensure-in-vscode-task() {
	if ! in-vscode "${rootPath}"; then
		log "Not in vscode" "error"
		exit 1
	fi
	exit 0
}

function main() {
	local relativeRootPath
	local rootPath
	relativeRootPath="$(dirname "${0}")/.."
	rootPath="$(realpath "${relativeRootPath}")"

	local task="${1}" ; shift
	if [[ "${task}" == "ensure-in-vscode" ]] ; then
		ensure-in-vscode-task
	fi

	local codeServerVersion="${1}" ; shift
	local vscodeVersion="${1}" ; shift
	local target="${1}" ; shift
	local arch="${1}" ; shift
	local ci="${CI:-}"

	# This lets you build in a separate directory since building within this
	# directory while developing makes it hard to keep developing since compiling
	# will compile everything in the build directory as well.
	local outPath="${OUT:-${rootPath}}"

	# If we're inside a vscode directory, assume we want to develop. In that case
	# we should set an OUT directory and not build in this directory.
	if in-vscode "${outPath}" ; then
		log "Set the OUT environment variable to something outside of VS Code" "error"
		exit 1
	fi

	local releasePath="${outPath}/release"
	local buildPath="${outPath}/build"

	local vscodeSourceName="vscode-${vscodeVersion}-source"
	local vscodeBuildName="vscode-${vscodeVersion}-${target}-${arch}-built"
	local vscodeSourcePath="${buildPath}/${vscodeSourceName}"
	local vscodeBuildPath="${buildPath}/${vscodeBuildName}"

	local codeServerBuildName="code-server${codeServerVersion}-vsc${vscodeVersion}-${target}-${arch}-built"
	local codeServerBuildPath="${buildPath}/${codeServerBuildName}"
	local binaryName="code-server${codeServerVersion}-vsc${vscodeVersion}-${target}-${arch}"

	log "Running ${task} task"
	log " rootPath: ${rootPath}"
	log " outPath: ${outPath}"
	log " codeServerVersion: ${codeServerVersion}"
	log " vscodeVersion: ${vscodeVersion}"
	log " target: ${target}"
	log " arch: ${arch}"
	if [[ -n "${ci}" ]] ; then
		log " CI: yes"
	else
		log " CI: no"
	fi

	"${task}-task" "$@"
}

main "$@"