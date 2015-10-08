#
# Cookbook Name:: omnibus
# HWRP:: omnibus_build
#
# Copyright 2015, Chef Software, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
require_relative 'helper'

class Chef
  class Resource::OmnibusBuild < Resource::LWRPBase
    resource_name :omnibus_build

    actions :execute
    default_action :execute

    attribute :project_name,
              kind_of: String,
              name_attribute: true
    attribute :project_dir,
              kind_of: String,
              required: true
    attribute :install_dir,
              kind_of: String,
              default: lazy { |r| ChefConfig.windows? ? ::File.join(ENV['SYSTEMDRIVE'], r.project_name) : "/opt/#{r.project_name}" }
    attribute :omnibus_base_dir,
              kind_of: String,
              default: lazy { ChefConfig.windows? ? ::File.join(ENV['SYSTEMDRIVE'], 'omnibus-ruby') : '/var/cache/omnibus' }
    attribute :log_level,
              kind_of: Symbol,
              equal_to: [:internal, :debug, :info, :warn, :error, :fatal],
              default: :internal
    attribute :config_file,
              kind_of: String,
              default: lazy { |r| ::File.join(r.project_dir, 'omnibus.rb') }
    attribute :config_overrides,
              kind_of: Hash,
              default: {}
    attribute :expire_cache,
              kind_of: [TrueClass, FalseClass],
              default: false
    attribute :build_user,
              kind_of: String,
              default: lazy { |r| r.node['omnibus']['build_user'] }
    attribute :environment,
              kind_of: Hash,
              default: {}
  end

  class Provider::OmnibusBuild < Provider::LWRPBase
    include Omnibus::Helper

    provides :omnibus_build

    def whyrun_supported?
      true
    end

    action(:execute) do
      converge_by("execute #{new_resource}") do
        prepare_build_enviornment
        # bundle install
        execute_with_omnibus_toolchain(bundle_install_command)
        # omnibus build
        execute_with_omnibus_toolchain("bundle exec #{build_command}")
      end
    end

    protected

    def bundle_install_command
      if ::File.exist?(::File.join(new_resource.project_dir, 'Gemfile.lock'))
        'bundle install --deployment'
      else
        'bundle install --path vendor/bundle'
      end
    end

    def build_command
      [
        'omnibus',
        'build',
        new_resource.project_name,
        "--log-level #{new_resource.log_level}",
        "--config #{new_resource.config_file}",
        "--override #{new_resource.config_overrides.map { |k, v| "#{k}:#{v}" }.join(' ')}"
      ].join(' ')
    end

    def prepare_build_enviornment
      # Optionally wipe all caches (including the git cache)
      if new_resource.expire_cache
        cache = Resource::Directory.new(new_resource.omnibus_base_dir, run_context)
        cache.recursive(true)
        cache.run_action(:delete)
      end

      # Clean up various directories from the last build
      %W(
        #{new_resource.omnibus_base_dir}/build/#{new_resource.project_name}/*.manifest
        #{new_resource.omnibus_base_dir}/pkg
        #{new_resource.project_dir}/pkg
        #{new_resource.install_dir}
      ).each do |directory|
        d = Resource::Directory.new(directory, run_context)
        d.recursive(true)
        d.run_action(:delete)
      end

      # Create required build directories with the correct ownership
      %W(
        #{new_resource.omnibus_base_dir}
        #{new_resource.install_dir}
      ).each do |directory|
        d = Resource::Directory.new(directory, run_context)
        d.owner(new_resource.build_user)
        d.run_action(:create)
      end
    end

    def execute_with_omnibus_toolchain(command)
      load_toolchain = if windows?
                         "call #{windows_safe_path_join(build_user_home, 'load-omnibus-toolchain.bat')}"
                       else
                         "source #{::File.join(build_user_home, 'load-omnibus-toolchain.sh')}"
                       end

      execute = Resource::Execute.new("#{new_resource.project_name}: #{command}", run_context)
      execute.command(
        <<-CODE.gsub(/^ {10}/, '')
          #{load_toolchain} && #{command}
        CODE
      )
      execute.cwd(new_resource.project_dir)
      execute.environment(new_resource.environment)
      execute.user(new_resource.build_user) unless windows?
      execute.run_action(:run)
    end
  end
end
