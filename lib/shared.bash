#!/bin/bash

# Show a prompt for a command
function plugin_prompt() {
  if [[ -z "${HIDE_PROMPT:-}" ]] ; then
    echo -ne '\033[90m$\033[0m' >&2
    printf " %q" "$@" >&2
    echo >&2
  fi
}

# Shows the command being run, and runs it
function plugin_prompt_and_run() {
  plugin_prompt "$@"
  "$@"
}

# Shows the command about to be run, and exits if it fails
function plugin_prompt_and_must_run() {
  plugin_prompt_and_run "$@" || exit $?
}

# Shorthand for reading env config
function plugin_read_config() {
  local var="BUILDKITE_PLUGIN_DOCKER_COMPOSE_${1}"
  local default="${2:-}"
  echo "${!var:-$default}"
}

# Reads either a value or a list from plugin config
function plugin_read_list() {
  local prefix="BUILDKITE_PLUGIN_DOCKER_COMPOSE_$1"
  local parameter="${prefix}_0"

  if [[ -n "${!parameter:-}" ]]; then
    local i=0
    local parameter="${prefix}_${i}"
    while [[ -n "${!parameter:-}" ]]; do
      echo "${!parameter}"
      i=$((i+1))
      parameter="${prefix}_${i}"
    done
  elif [[ -n "${!prefix:-}" ]]; then
    echo "${!prefix}"
  fi
}

# Returns the name of the docker compose project for this build
function docker_compose_project_name() {
  # No dashes or underscores because docker-compose will remove them anyways
  echo "buildkite${BUILDKITE_JOB_ID//-}"
}

# Runs docker ps -a filtered by the current project name
function docker_ps_by_project() {
  docker ps -a \
    --filter "label=com.docker.compose.project=$(docker_compose_project_name)" \
    "${@}"
}

# Returns all docker compose config file names split by newlines
function docker_compose_config_files() {
  local -a config_files=()

  # Parse the list of config files into an array
  while read -r line ; do
    [[ -n "$line" ]] && config_files+=("$line")
  done <<< "$(plugin_read_list CONFIG)"

  if [[ ${#config_files[@]:-} -eq 0 ]]  ; then
    echo "docker-compose.yml"
    return
  fi

  # Process any (deprecated) colon delimited config paths
  for value in "${config_files[@]}" ; do
    echo "$value" | tr ':' '\n'
  done
}

# Returns the version from the output of docker_compose_config
function docker_compose_config_version() {
  IFS=$'\n' read -r -a config <<< "$(docker_compose_config_files)"
  awk '/\s*version:/ { print $2; }' < "${config[0]}" | sed "s/[\"']//g"
}

# Build an docker-compose file that overrides the image for a set of
# service and image pairs
function build_image_override_file() {
  build_image_override_file_with_version \
    "$(docker_compose_config_version)" "$@"
}

# Build an docker-compose file that overrides the image for a specific
# docker-compose version and set of service and image pairs
function build_image_override_file_with_version() {
  local version="$1"

  if [[ -z "$version" ]]; then
    echo "The 'build' option can only be used with Compose file versions 2.0 and above."
    echo "For more information on Docker Compose configuration file versions, see:"
    echo "https://docs.docker.com/compose/compose-file/compose-versioning/#versioning"
    exit 1
  fi

  printf "version: '%s'\\n" "$version"
  printf "services:\\n"

  shift
  while test ${#} -gt 0 ; do
    printf "  %s:\\n" "$1"
    printf "    image: %s\\n" "$2"

    if [[ -n "$3" ]] ; then
      if [[ -z "$version" || "$version" == 2* || "$version" == 3 || "$version" == 3.0* || "$version" == 3.1* ]]; then
        echo "Unsupported Docker Compose config file version: $version"
        echo "The 'cache_from' option can only be used with Compose file versions 3.2 and above."
        echo "For more information on Docker Compose configuration file versions, see:"
        echo "https://docs.docker.com/compose/compose-file/compose-versioning/#versioning"
        exit 1
      fi

      printf "    build:\\n"
      printf "      cache_from:\\n"
      printf "        - %s\\n" "$3"
    fi

    shift 3
  done
}

# Runs the docker-compose command, scoped to the project, with the given arguments
function run_docker_compose() {
  local command=(docker-compose)

  if [[ "$(plugin_read_config VERBOSE "false")" == "true" ]] ; then
    command+=(--verbose)
  fi

  for file in $(docker_compose_config_files) ; do
    command+=(-f "$file")
  done

  command+=(-p "$(docker_compose_project_name)")

  for token in "${@}" ; do
    echo "token[$token]"
  done

  plugin_prompt_and_run "${command[@]}" "$@"
}

function build_image_name() {
  local service_name="$1"
  local default="${BUILDKITE_PIPELINE_SLUG}-${service_name}-build-${BUILDKITE_BUILD_NUMBER}"
  plugin_read_config IMAGE_NAME "$default"
}

function in_array() {
  local e
  for e in "${@:2}"; do [[ "$e" == "$1" ]] && return 0; done
  return 1
}

# retry <number-of-retries> <command>
function retry {
  local retries=$1; shift
  local attempts=1
  local status=0

  until "$@"; do
    status=$?
    echo "Exited with $status"
    if (( retries == "0" )); then
      return $status
    elif (( attempts == retries )); then
      echo "Failed $attempts retries"
      return $status
    else
      echo "Retrying $((retries - attempts)) more times..."
      attempts=$((attempts + 1))
      sleep $(((attempts - 2) * 2))
    fi
  done

  echo "$status"
}
