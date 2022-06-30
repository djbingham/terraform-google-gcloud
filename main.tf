/**
 * Copyright 2018 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

locals {
  tmp_credentials_path  = "${path.module}/terraform-google-credentials.json"
  cache_path            = local.skip_download ? "" : (var.cache_path != null) ? var.cache_path : "${path.module}/cache/${random_id.cache[0].hex}"
  cache_path_gcloud_tar = "${local.cache_path}/google-cloud-sdk.tar.gz"
  cache_path_jq         = "${local.cache_path}/jq"
  bin_path              = "${local.cache_path}/google-cloud-sdk/bin"
  bin_abs_path          = abspath(local.bin_path)
  bin_path_gcloud       = "${local.bin_path}/gcloud"
  bin_path_jq           = "${local.bin_path}/jq"
  components            = join(",", var.additional_components)

  download_override = var.enabled ? var.TF_VAR_GCLOUD_DOWNLOAD : ""
  skip_download     = local.download_override == "always" ? false : (local.download_override == "never" ? true : var.skip_download)

  gcloud              = local.skip_download ? "gcloud" : local.bin_path_gcloud
  gcloud_download_url = var.gcloud_download_url != "" ? var.gcloud_download_url : "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-${var.gcloud_sdk_version}-${var.platform}-x86_64.tar.gz"

  jq_platform     = var.platform == "darwin" ? "osx-amd" : var.platform
  jq_download_url = var.jq_download_url != "" ? var.jq_download_url : "https://github.com/stedolan/jq/releases/download/jq-${var.jq_version}/jq-${local.jq_platform}64"

  #  Steps to install gcloud SDK
  prepare_cache_command   = "mkdir -p ${local.cache_path}"
  download_gcloud_command = "curl -sL -o ${local.cache_path_gcloud_tar} ${local.gcloud_download_url}"
  download_jq_command     = "curl -sL -o ${local.cache_path_jq} ${local.jq_download_url} && chmod +x ${local.cache_path_jq}"
  decompress_command      = "tar -xzf ${local.cache_path_gcloud_tar} -C ${local.cache_path}/ && cp ${local.cache_path_jq} ${local.bin_path}/"
  upgrade_command         = var.upgrade ? "${local.gcloud} components update --quiet" : ":"

  # Optional steps to prepare gcloud environment
  additional_components_command                = "${path.module}/scripts/check_components.sh ${local.gcloud} ${local.components}"
  gcloud_auth_service_account_key_file_command = "${local.gcloud} auth activate-service-account --key-file ${var.service_account_key_file}"
  gcloud_auth_google_credentials_command       = <<-EOT
    printf "%s" "$GOOGLE_CREDENTIALS" > ${local.tmp_credentials_path} &&
    ${local.gcloud} auth activate-service-account --key-file ${local.tmp_credentials_path}
  EOT

  # Triggers for executing the requested commands
  create_cmd_triggers = merge({
    md5                   = md5(var.create_cmd_entrypoint)
    arguments             = md5(var.create_cmd_body)
    create_cmd_entrypoint = var.create_cmd_entrypoint
    create_cmd_body       = var.create_cmd_body
    bin_abs_path          = local.bin_abs_path
  }, var.create_cmd_triggers)

  destroy_cmd_triggers = merge({
    destroy_md5            = md5(var.destroy_cmd_entrypoint)
    destroy_arguments      = md5(var.destroy_cmd_body)
    destroy_cmd_entrypoint = var.destroy_cmd_entrypoint
    destroy_cmd_body       = var.destroy_cmd_body
  }, local.create_cmd_triggers)

  # Outputs (not used internally)
  create_cmd_bin  = local.skip_download ? var.create_cmd_entrypoint : "${local.bin_path}/${var.create_cmd_entrypoint}"
  destroy_cmd_bin = local.skip_download ? var.destroy_cmd_entrypoint : "${local.bin_path}/${var.destroy_cmd_entrypoint}"

  wait = <<-EOT
    ${length(null_resource.additional_components.*.triggers)} +
    ${length(null_resource.gcloud_auth_service_account_key_file.*.triggers, )} +
    ${length(null_resource.gcloud_auth_google_credentials.*.triggers, )} +
    ${length(null_resource.run_command.*.triggers)} +
    ${length(null_resource.run_destroy_command.*.triggers)}
  EOT
}

resource "random_id" "cache" {
  count = (!local.skip_download) ? 1 : 0

  byte_length = 4
}

resource "null_resource" "module_depends_on" {
  count = length(var.module_depends_on) > 0 ? 1 : 0

  triggers = {
    value = length(var.module_depends_on)
  }
}

resource "null_resource" "install_gcloud" {
  count = (var.enabled && !local.skip_download) ? 1 : 0

  depends_on = [
    null_resource.module_depends_on,
    // Ensure destroy steps run after gcloud is installed (dependency order is reversed on destroy)
    null_resource.additional_components_destroy,
    null_resource.gcloud_auth_service_account_key_file_destroy,
    null_resource.gcloud_auth_google_credentials_destroy
  ]

  triggers = merge(
    {
      decompress_command                           = local.decompress_command
      download_jq_command                          = local.download_jq_command
      download_gcloud_command                      = local.download_gcloud_command
      prepare_cache_command                        = local.prepare_cache_command
      upgrade_command                              = local.upgrade_command
      gcloud_auth_google_credentials_command       = local.gcloud_auth_google_credentials_command
      gcloud_auth_service_account_key_file_command = local.gcloud_auth_service_account_key_file_command
      additional_components_command                = local.additional_components_command
    },
    local.create_cmd_triggers,
    local.destroy_cmd_triggers
  )

  provisioner "local-exec" {
    when    = create
    command = self.triggers.prepare_cache_command
  }

  provisioner "local-exec" {
    when    = destroy
    command = self.triggers.prepare_cache_command
  }

  provisioner "local-exec" {
    when    = create
    command = !fileexists("${local.cache_path_jq}") ? self.triggers.download_jq_command : ":"
  }

  provisioner "local-exec" {
    when    = destroy
    command = self.triggers.download_jq_command
  }

  provisioner "local-exec" {
    when    = create
    command = !fileexists(local.cache_path_gcloud_tar) ? self.triggers.download_gcloud_command : ":"
  }

  provisioner "local-exec" {
    when    = destroy
    command = self.triggers.download_gcloud_command
  }

  provisioner "local-exec" {
    when    = create
    command = !(fileexists("${local.bin_path_gcloud}") && fileexists("${local.bin_path_jq}")) ? self.triggers.decompress_command : ":"
  }

  provisioner "local-exec" {
    when    = destroy
    command = self.triggers.decompress_command
  }

  provisioner "local-exec" {
    when    = create
    command = self.triggers.upgrade_command
  }

  provisioner "local-exec" {
    when    = destroy
    command = self.triggers.upgrade_command
  }
}

resource "null_resource" "additional_components" {
  count = var.enabled && length(var.additional_components) > 0 ? 1 : 0

  depends_on = [null_resource.install_gcloud]

  triggers = merge({
    additional_components_command = local.additional_components_command
  }, local.create_cmd_triggers)

  provisioner "local-exec" {
    when    = create
    command = self.triggers.additional_components_command
  }
}

resource "null_resource" "gcloud_auth_service_account_key_file" {
  count = var.enabled && length(var.service_account_key_file) > 0 ? 1 : 0

  depends_on = [null_resource.install_gcloud]

  triggers = merge({
    gcloud_auth_service_account_key_file_command = local.gcloud_auth_service_account_key_file_command
  }, local.create_cmd_triggers)

  provisioner "local-exec" {
    when    = create
    command = self.triggers.gcloud_auth_service_account_key_file_command
  }
}

resource "null_resource" "gcloud_auth_google_credentials" {
  count = var.enabled && var.use_tf_google_credentials_env_var ? 1 : 0

  depends_on = [null_resource.install_gcloud]

  triggers = merge({
    gcloud_auth_google_credentials_command = local.gcloud_auth_google_credentials_command
  }, local.create_cmd_triggers)

  provisioner "local-exec" {
    when    = create
    command = self.triggers.gcloud_auth_google_credentials_command
  }
}

resource "null_resource" "run_command" {
  count = var.enabled ? 1 : 0

  depends_on = [
    null_resource.module_depends_on,
    null_resource.install_gcloud,
    null_resource.additional_components,
    null_resource.gcloud_auth_google_credentials,
    null_resource.gcloud_auth_service_account_key_file
  ]

  triggers = local.create_cmd_triggers

  provisioner "local-exec" {
    when    = create
    command = <<-EOT
    PATH=${self.triggers.bin_abs_path}:$PATH
    ${self.triggers.create_cmd_entrypoint} ${self.triggers.create_cmd_body}
    EOT
  }
}

resource "null_resource" "run_destroy_command" {
  count = var.enabled ? 1 : 0

  depends_on = [
    null_resource.module_depends_on
  ]

  triggers = local.destroy_cmd_triggers

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
    PATH=${self.triggers.bin_abs_path}:$PATH
    ${self.triggers.destroy_cmd_entrypoint} ${self.triggers.destroy_cmd_body}
    EOT
  }
}

// Destroy provision steps in opposite depenency order
// so they run before `run_destroy_command` on destroy
resource "null_resource" "gcloud_auth_google_credentials_destroy" {
  count = var.enabled && var.use_tf_google_credentials_env_var ? 1 : 0

  depends_on = [null_resource.run_destroy_command]

  triggers = merge({
    gcloud_auth_google_credentials_command = local.gcloud_auth_google_credentials_command
  }, local.destroy_cmd_triggers)

  provisioner "local-exec" {
    when    = destroy
    command = self.triggers.gcloud_auth_google_credentials_command
  }
}

resource "null_resource" "gcloud_auth_service_account_key_file_destroy" {
  count = var.enabled && length(var.service_account_key_file) > 0 ? 1 : 0

  depends_on = [null_resource.run_destroy_command]

  triggers = merge({
    gcloud_auth_service_account_key_file_command = local.gcloud_auth_service_account_key_file_command
  }, local.destroy_cmd_triggers)

  provisioner "local-exec" {
    when    = destroy
    command = self.triggers.gcloud_auth_service_account_key_file_command
  }
}

resource "null_resource" "additional_components_destroy" {
  count = var.enabled && length(var.additional_components) > 0 ? 1 : 0

  depends_on = [null_resource.run_destroy_command]

  triggers = merge({
    additional_components_command = local.additional_components_command
  }, local.destroy_cmd_triggers)

  provisioner "local-exec" {
    when    = destroy
    command = self.triggers.additional_components_command
  }
}
