#!/bin/bash

# Copyright 2019 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

cleanup() {
    rm -f cloudep.yaml
}
trap cleanup EXIT

NAME=$1
TARGET=$2
PROJECT=${3:-${GOOGLE_CLOUD_PROJECT:-$(gcloud config get-value project 2>/dev/null)}}

[[ -z "${NAME}" || -z "${TARGET}" || -z "${PROJECT}" ]] && echo "USAGE: $0 <name> <target ip> [<project>]" >&2 && exit 1

SVC=${NAME}.endpoints.${PROJECT}.cloud.goog

cat - > cloudep.yaml <<EOF
swagger: "2.0"
info:
  description: "Cloud Endpoints DNS"
  title: "Cloud Endpoints DNS"
  version: "1.0.0"
paths: {}
host: "${SVC}"
x-google-endpoints:
- name: "${SVC}"
  target: "${TARGET}"
EOF

gcloud -q endpoints services deploy cloudep.yaml 1>&2

gcloud endpoints services describe ${SVC} --format='value(serviceConfig.id)'