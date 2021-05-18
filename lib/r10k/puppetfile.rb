require 'thread'
require 'pathname'
require 'r10k/module'
require 'r10k/util/purgeable'
require 'r10k/errors'
require 'r10k/content_synchronizer'
require 'r10k/module_loader/puppetfile/dsl'
require 'r10k/module_loader/puppetfile'

module R10K
class Puppetfile
  # Defines the data members of a Puppetfile

  NotGiven = BasicObject.new

  include R10K::Settings::Mixin

  def_setting_attr :pool_size, 4

  include R10K::Logging

  # @!attribute [r] forge
  #   @return [String] The URL to use for the Puppet Forge
  attr_reader :forge

  # @!attribute [r] basedir
  #   @return [String] The base directory that contains the Puppetfile
  attr_reader :basedir

  # @!attrbute [r] puppetfile_path
  #   @return [String] The path to the Puppetfile
  attr_reader :puppetfile_path

  # @!attribute [r] environment
  #   @return [R10K::Environment] Optional R10K::Environment that this Puppetfile belongs to.
  attr_reader :environment

  # @!attribute [rw] force
  #   @return [Boolean] Overwrite any locally made changes
  attr_accessor :force

  # @!attribute [r] overrides
  #   @return [Hash] Various settings overridden from normal configs
  attr_reader :overrides

  # @param [String] basedir
  # @param [Hash, String, nil] options_or_moduledir The directory to install the modules or a Hash of options.
  #         Usage as moduledir is deprecated. Only use as options, defaults to nil
  # @param [String, nil] puppetfile_path Deprecated - The path to the Puppetfile, defaults to nil
  # @param [String, nil] puppetfile_name Deprecated - The name of the Puppetfile, defaults to nil
  # @param [Boolean, nil] force Deprecated - Shall we overwrite locally made changes?
  def initialize(basedir, options_or_moduledir = nil, deprecated_path_arg = nil, deprecated_name_arg = nil, deprecated_force_arg = nil)
    @basedir         = basedir
    if options_or_moduledir.is_a? Hash
      options = options_or_moduledir
      deprecated_moduledir_arg = nil
    else
      options = {}
      deprecated_moduledir_arg = options_or_moduledir
    end

    @force           = deprecated_force_arg     || options.delete(:force)           || false
    @moduledir       = deprecated_moduledir_arg || options.delete(:moduledir)       || File.join(basedir, 'modules')
    @puppetfile_name = deprecated_name_arg      || options.delete(:puppetfile_name) || 'Puppetfile'
    @puppetfile_path = deprecated_path_arg      || options.delete(:puppetfile_path) || File.join(basedir, @puppetfile_name)
    @environment     = options.delete(:environment)

    @overrides       = options.delete(:overrides) || {}
    @default_branch_override = @overrides.dig(:environments, :default_branch_overrides)

    logger.info _("Using Puppetfile '%{puppetfile}'") % {puppetfile: @puppetfile_path}

    @forge   = 'forgeapi.puppetlabs.com'

    @loader = ::R10K::ModuleLoader::Puppetfile.new(
      puppetfile: @puppetfile_path,
      moduledir: @moduledir,
      forge: @forge,
      basedir: @basedir,
      overrides: @overrides,
      environment: @environment
    )

    @loaded = false
  end

  def load(default_branch_override = NotGiven)
    if self.loaded?
      return true 
    else
      self.load!(default_branch_override)
    end
  end

  def load!(dbo = NotGiven)
    if (dbo != NotGiven) && (dbo != @default_branch_override)
      logger.warn("Mismatch between passed and initialized default branch overrides, preferring passed value.")
      @loader.default_branch_override = dbo
    end

    @loader.load!
    @loaded = true
  end

  def loaded?
    @loaded
  end

  def modules
    @loader.modules
  end

  def add_module(name, args)
    @loader.add_module(name, args)
  end

  def set_moduledir(dir)
    @loader.set_moduledir(dir)
  end

  def set_forge(forge)
    @loader.set_forge(forge)
  end

  def moduledir
    @loader.moduledir
  end

  def environment=(env)
    @loader.environment = env
    @environment = env
  end

  include R10K::Util::Purgeable

  def managed_content
    @loader.managed_content
  end

  def managed_directories
    self.load unless @loaded

    dirs = managed_content.keys
    dirs.delete(real_basedir)
    dirs
  end

  # Returns an array of the full paths to all the content being managed.
  # @note This implements a required method for the Purgeable mixin
  # @return [Array<String>]
  def desired_contents
    self.load unless self.loaded?

    managed_content.flat_map do |install_path, modnames|
      modnames.collect { |name| File.join(install_path, name) }
    end
  end

  def purge_exclusions
    exclusions = managed_directories

    if environment && environment.respond_to?(:desired_contents)
      exclusions += environment.desired_contents
    end

    exclusions
  end

  def accept(visitor)
    pool_size = self.settings[:pool_size]
    if pool_size > 1
      R10K::ContentSynchronizer.concurrent_accept(modules, visitor, self, pool_size, logger)
    else
      R10K::ContentSynchronizer.serial_accept(modules, visitor, self)
    end
  end

  def sync
    pool_size = self.settings[:pool_size]
    if pool_size > 1
      R10K::ContentSynchronizer.concurrent_sync(modules, pool_size, logger)
    else
      R10K::ContentSynchronizer.serial_sync(modules)
    end
  end

  private

  def real_basedir
    Pathname.new(basedir).cleanpath.to_s
  end

  DSL = R10K::ModuleLoader::Puppetfile::DSL
end
end
