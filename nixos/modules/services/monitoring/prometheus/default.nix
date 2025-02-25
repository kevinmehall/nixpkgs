{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.prometheus;

  workingDir = "/var/lib/" + cfg.stateDir;

  prometheusYmlOut = "${workingDir}/prometheus-substituted.yaml";

  writeConfig = pkgs.writeShellScriptBin "write-prometheus-config" ''
    PATH="${makeBinPath (with pkgs; [ coreutils envsubst ])}"
    touch '${prometheusYmlOut}'
    chmod 600 '${prometheusYmlOut}'
    envsubst -o '${prometheusYmlOut}' -i '${prometheusYml}'
  '';

  triggerReload = pkgs.writeShellScriptBin "trigger-reload-prometheus" ''
    PATH="${makeBinPath (with pkgs; [ systemd ])}"
    if systemctl -q is-active prometheus.service; then
      systemctl reload prometheus.service
    fi
  '';

  reload = pkgs.writeShellScriptBin "reload-prometheus" ''
    PATH="${makeBinPath (with pkgs; [ systemd coreutils gnugrep ])}"
    cursor=$(journalctl --show-cursor -n0 | grep -oP "cursor: \K.*")
    kill -HUP $MAINPID
    journalctl -u prometheus.service --after-cursor="$cursor" -f \
      | grep -m 1 "Completed loading of configuration file" > /dev/null
  '';

  # a wrapper that verifies that the configuration is valid
  promtoolCheck = what: name: file:
    if cfg.checkConfig then
      pkgs.runCommandLocal
        "${name}-${replaceStrings [" "] [""] what}-checked"
        { buildInputs = [ cfg.package ]; } ''
      ln -s ${file} $out
      promtool ${what} $out
    '' else file;

  # Pretty-print JSON to a file
  writePrettyJSON = name: x:
    pkgs.runCommandLocal name {} ''
      echo '${builtins.toJSON x}' | ${pkgs.jq}/bin/jq . > $out
    '';

  generatedPrometheusYml = writePrettyJSON "prometheus.yml" promConfig;

  # This becomes the main config file for Prometheus
  promConfig = {
    global = filterValidPrometheus cfg.globalConfig;
    rule_files = map (promtoolCheck "check rules" "rules") (cfg.ruleFiles ++ [
      (pkgs.writeText "prometheus.rules" (concatStringsSep "\n" cfg.rules))
    ]);
    scrape_configs = filterValidPrometheus cfg.scrapeConfigs;
    remote_write = filterValidPrometheus cfg.remoteWrite;
    remote_read = filterValidPrometheus cfg.remoteRead;
    alerting = {
      inherit (cfg) alertmanagers;
    };
  };

  prometheusYml = let
    yml = if cfg.configText != null then
      pkgs.writeText "prometheus.yml" cfg.configText
      else generatedPrometheusYml;
    in promtoolCheck "check config" "prometheus.yml" yml;

  cmdlineArgs = cfg.extraFlags ++ [
    "--storage.tsdb.path=${workingDir}/data/"
    "--config.file=${
      if cfg.enableReload
      then prometheusYmlOut
      else "/run/prometheus/prometheus-substituted.yaml"
    }"
    "--web.listen-address=${cfg.listenAddress}:${builtins.toString cfg.port}"
    "--alertmanager.notification-queue-capacity=${toString cfg.alertmanagerNotificationQueueCapacity}"
    "--alertmanager.timeout=${toString cfg.alertmanagerTimeout}s"
  ] ++ optional (cfg.webExternalUrl != null) "--web.external-url=${cfg.webExternalUrl}"
    ++ optional (cfg.retentionTime != null)  "--storage.tsdb.retention.time=${cfg.retentionTime}";

  filterValidPrometheus = filterAttrsListRecursive (n: v: !(n == "_module" || v == null));
  filterAttrsListRecursive = pred: x:
    if isAttrs x then
      listToAttrs (
        concatMap (name:
          let v = x.${name}; in
          if pred name v then [
            (nameValuePair name (filterAttrsListRecursive pred v))
          ] else []
        ) (attrNames x)
      )
    else if isList x then
      map (filterAttrsListRecursive pred) x
    else x;

  mkDefOpt = type : defaultStr : description : mkOpt type (description + ''

    Defaults to <literal>${defaultStr}</literal> in prometheus
    when set to <literal>null</literal>.
  '');

  mkOpt = type : description : mkOption {
    type = types.nullOr type;
    default = null;
    inherit description;
  };

  promTypes.globalConfig = types.submodule {
    options = {
      scrape_interval = mkDefOpt types.str "1m" ''
        How frequently to scrape targets by default.
      '';

      scrape_timeout = mkDefOpt types.str "10s" ''
        How long until a scrape request times out.
      '';

      evaluation_interval = mkDefOpt types.str "1m" ''
        How frequently to evaluate rules by default.
      '';

      external_labels = mkOpt (types.attrsOf types.str) ''
        The labels to add to any time series or alerts when
        communicating with external systems (federation, remote
        storage, Alertmanager).
      '';
    };
  };

  promTypes.remote_read = types.submodule {
    options = {
      url = mkOption {
        type = types.str;
        description = ''
          ServerName extension to indicate the name of the server.
          http://tools.ietf.org/html/rfc4366#section-3.1
        '';
      };
      name = mkOpt types.str ''
        Name of the remote read config, which if specified must be unique among remote read configs.
        The name will be used in metrics and logging in place of a generated value to help users distinguish between
        remote read configs.
      '';
      required_matchers = mkOpt (types.attrsOf types.str) ''
        An optional list of equality matchers which have to be
        present in a selector to query the remote read endpoint.
      '';
      remote_timeout = mkOpt types.str ''
        Timeout for requests to the remote read endpoint.
      '';
      read_recent = mkOpt types.bool ''
        Whether reads should be made for queries for time ranges that
        the local storage should have complete data for.
      '';
      basic_auth = mkOpt (types.submodule {
        options = {
          username = mkOption {
            type = types.str;
            description = ''
              HTTP username
            '';
          };
          password = mkOpt types.str "HTTP password";
          password_file = mkOpt types.str "HTTP password file";
        };
      }) ''
        Sets the `Authorization` header on every remote read request with the
        configured username and password.
        password and password_file are mutually exclusive.
      '';
      bearer_token = mkOpt types.str ''
        Sets the `Authorization` header on every remote read request with
        the configured bearer token. It is mutually exclusive with `bearer_token_file`.
      '';
      bearer_token_file = mkOpt types.str ''
        Sets the `Authorization` header on every remote read request with the bearer token
        read from the configured file. It is mutually exclusive with `bearer_token`.
      '';
      tls_config = mkOpt promTypes.tls_config ''
        Configures the remote read request's TLS settings.
      '';
      proxy_url = mkOpt types.str "Optional Proxy URL.";
    };
  };

  promTypes.remote_write = types.submodule {
    options = {
      url = mkOption {
        type = types.str;
        description = ''
          ServerName extension to indicate the name of the server.
          http://tools.ietf.org/html/rfc4366#section-3.1
        '';
      };
      remote_timeout = mkOpt types.str ''
        Timeout for requests to the remote write endpoint.
      '';
      write_relabel_configs = mkOpt (types.listOf promTypes.relabel_config) ''
        List of remote write relabel configurations.
      '';
      name = mkOpt types.str ''
        Name of the remote write config, which if specified must be unique among remote write configs.
        The name will be used in metrics and logging in place of a generated value to help users distinguish between
        remote write configs.
      '';
      basic_auth = mkOpt (types.submodule {
        options = {
          username = mkOption {
            type = types.str;
            description = ''
              HTTP username
            '';
          };
          password = mkOpt types.str "HTTP password";
          password_file = mkOpt types.str "HTTP password file";
        };
      }) ''
        Sets the `Authorization` header on every remote write request with the
        configured username and password.
        password and password_file are mutually exclusive.
      '';
      bearer_token = mkOpt types.str ''
        Sets the `Authorization` header on every remote write request with
        the configured bearer token. It is mutually exclusive with `bearer_token_file`.
      '';
      bearer_token_file = mkOpt types.str ''
        Sets the `Authorization` header on every remote write request with the bearer token
        read from the configured file. It is mutually exclusive with `bearer_token`.
      '';
      tls_config = mkOpt promTypes.tls_config ''
        Configures the remote write request's TLS settings.
      '';
      proxy_url = mkOpt types.str "Optional Proxy URL.";
      queue_config = mkOpt (types.submodule {
        options = {
          capacity = mkOpt types.int ''
            Number of samples to buffer per shard before we block reading of more
            samples from the WAL. It is recommended to have enough capacity in each
            shard to buffer several requests to keep throughput up while processing
            occasional slow remote requests.
          '';
          max_shards = mkOpt types.int ''
            Maximum number of shards, i.e. amount of concurrency.
          '';
          min_shards = mkOpt types.int ''
            Minimum number of shards, i.e. amount of concurrency.
          '';
          max_samples_per_send = mkOpt types.int ''
            Maximum number of samples per send.
          '';
          batch_send_deadline = mkOpt types.str ''
            Maximum time a sample will wait in buffer.
          '';
          min_backoff = mkOpt types.str ''
            Initial retry delay. Gets doubled for every retry.
          '';
          max_backoff = mkOpt types.str ''
            Maximum retry delay.
          '';
        };
      }) ''
        Configures the queue used to write to remote storage.
      '';
      metadata_config = mkOpt (types.submodule {
        options = {
          send = mkOpt types.bool ''
            Whether metric metadata is sent to remote storage or not.
          '';
          send_interval = mkOpt types.str ''
            How frequently metric metadata is sent to remote storage.
          '';
        };
      }) ''
        Configures the sending of series metadata to remote storage.
        Metadata configuration is subject to change at any point
        or be removed in future releases.
      '';
    };
  };

  promTypes.scrape_config = types.submodule {
    options = {
      job_name = mkOption {
        type = types.str;
        description = ''
          The job name assigned to scraped metrics by default.
        '';
      };
      scrape_interval = mkOpt types.str ''
        How frequently to scrape targets from this job. Defaults to the
        globally configured default.
      '';

      scrape_timeout = mkOpt types.str ''
        Per-target timeout when scraping this job. Defaults to the
        globally configured default.
      '';

      metrics_path = mkDefOpt types.str "/metrics" ''
        The HTTP resource path on which to fetch metrics from targets.
      '';

      honor_labels = mkDefOpt types.bool "false" ''
        Controls how Prometheus handles conflicts between labels
        that are already present in scraped data and labels that
        Prometheus would attach server-side ("job" and "instance"
        labels, manually configured target labels, and labels
        generated by service discovery implementations).

        If honor_labels is set to "true", label conflicts are
        resolved by keeping label values from the scraped data and
        ignoring the conflicting server-side labels.

        If honor_labels is set to "false", label conflicts are
        resolved by renaming conflicting labels in the scraped data
        to "exported_&lt;original-label&gt;" (for example
        "exported_instance", "exported_job") and then attaching
        server-side labels. This is useful for use cases such as
        federation, where all labels specified in the target should
        be preserved.
      '';

      honor_timestamps = mkDefOpt types.bool "true" ''
        honor_timestamps controls whether Prometheus respects the timestamps present
        in scraped data.

        If honor_timestamps is set to <literal>true</literal>, the timestamps of the metrics exposed
        by the target will be used.

        If honor_timestamps is set to <literal>false</literal>, the timestamps of the metrics exposed
        by the target will be ignored.
      '';

      scheme = mkDefOpt (types.enum ["http" "https"]) "http" ''
        The URL scheme with which to fetch metrics from targets.
      '';

      params = mkOpt (types.attrsOf (types.listOf types.str)) ''
        Optional HTTP URL parameters.
      '';

      basic_auth = mkOpt (types.submodule {
        options = {
          username = mkOption {
            type = types.str;
            description = ''
              HTTP username
            '';
          };
          password = mkOpt types.str "HTTP password";
          password_file = mkOpt types.str "HTTP password file";
        };
      }) ''
        Sets the `Authorization` header on every scrape request with the
        configured username and password.
        password and password_file are mutually exclusive.
      '';

      bearer_token = mkOpt types.str ''
        Sets the `Authorization` header on every scrape request with
        the configured bearer token. It is mutually exclusive with
        <option>bearer_token_file</option>.
      '';

      bearer_token_file = mkOpt types.str ''
        Sets the `Authorization` header on every scrape request with
        the bearer token read from the configured file. It is mutually
        exclusive with <option>bearer_token</option>.
      '';

      tls_config = mkOpt promTypes.tls_config ''
        Configures the scrape request's TLS settings.
      '';

      proxy_url = mkOpt types.str ''
        Optional proxy URL.
      '';

      ec2_sd_configs = mkOpt (types.listOf promTypes.ec2_sd_config) ''
        List of EC2 service discovery configurations.
      '';

      dns_sd_configs = mkOpt (types.listOf promTypes.dns_sd_config) ''
        List of DNS service discovery configurations.
      '';

      consul_sd_configs = mkOpt (types.listOf promTypes.consul_sd_config) ''
        List of Consul service discovery configurations.
      '';

      file_sd_configs = mkOpt (types.listOf promTypes.file_sd_config) ''
        List of file service discovery configurations.
      '';

      gce_sd_configs = mkOpt (types.listOf promTypes.gce_sd_config) ''
        List of Google Compute Engine service discovery configurations.

        See <link
        xlink:href="https://prometheus.io/docs/prometheus/latest/configuration/configuration/#gce_sd_config">the
        relevant Prometheus configuration docs</link> for more detail.
      '';

      static_configs = mkOpt (types.listOf promTypes.static_config) ''
        List of labeled target groups for this job.
      '';

      relabel_configs = mkOpt (types.listOf promTypes.relabel_config) ''
        List of relabel configurations.
      '';

      metric_relabel_configs = mkOpt (types.listOf promTypes.relabel_config) ''
        List of metric relabel configurations.
      '';

      sample_limit = mkDefOpt types.int "0" ''
        Per-scrape limit on number of scraped samples that will be accepted.
        If more than this number of samples are present after metric relabelling
        the entire scrape will be treated as failed. 0 means no limit.
      '';
    };
  };

  promTypes.static_config = types.submodule {
    options = {
      targets = mkOption {
        type = types.listOf types.str;
        description = ''
          The targets specified by the target group.
        '';
      };
      labels = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = ''
          Labels assigned to all metrics scraped from the targets.
        '';
      };
    };
  };

  promTypes.ec2_sd_config = types.submodule {
    options = {
      region = mkOption {
        type = types.str;
        description = ''
          The AWS Region.
        '';
      };
      endpoint = mkOpt types.str ''
        Custom endpoint to be used.
      '';

      access_key = mkOpt types.str ''
        The AWS API key id. If blank, the environment variable
        <literal>AWS_ACCESS_KEY_ID</literal> is used.
      '';

      secret_key = mkOpt types.str ''
        The AWS API key secret. If blank, the environment variable
         <literal>AWS_SECRET_ACCESS_KEY</literal> is used.
      '';

      profile = mkOpt  types.str ''
        Named AWS profile used to connect to the API.
      '';

      role_arn = mkOpt types.str ''
        AWS Role ARN, an alternative to using AWS API keys.
      '';

      refresh_interval = mkDefOpt types.str "60s" ''
        Refresh interval to re-read the instance list.
      '';

      port = mkDefOpt types.int "80" ''
        The port to scrape metrics from. If using the public IP
        address, this must instead be specified in the relabeling
        rule.
      '';

      filters = mkOpt (types.listOf promTypes.filter) ''
        Filters can be used optionally to filter the instance list by other criteria.
      '';
    };
  };

  promTypes.filter = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = ''
          See <link xlink:href="https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_DescribeInstances.html">this list</link>
          for the available filters.
        '';
      };

      values = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Value of the filter.
        '';
      };
    };
  };

  promTypes.dns_sd_config = types.submodule {
    options = {
      names = mkOption {
        type = types.listOf types.str;
        description = ''
          A list of DNS SRV record names to be queried.
        '';
      };

      refresh_interval = mkDefOpt types.str "30s" ''
        The time after which the provided names are refreshed.
      '';
    };
  };

  promTypes.consul_sd_config = types.submodule {
    options = {
      server = mkDefOpt types.str "localhost:8500" ''
        Consul server to query.
      '';

      token = mkOpt types.str "Consul token";

      datacenter = mkOpt types.str "Consul datacenter";

      scheme = mkDefOpt types.str "http" "Consul scheme";

      username = mkOpt types.str "Consul username";

      password = mkOpt types.str "Consul password";

      tls_config = mkOpt promTypes.tls_config ''
        Configures the Consul request's TLS settings.
      '';

      services = mkOpt (types.listOf types.str) ''
        A list of services for which targets are retrieved.
      '';

      tags = mkOpt (types.listOf types.str) ''
        An optional list of tags used to filter nodes for a given
        service. Services must contain all tags in the list.
      '';

      node_meta = mkOpt (types.attrsOf types.str) ''
        Node metadata used to filter nodes for a given service.
      '';

      tag_separator = mkDefOpt types.str "," ''
        The string by which Consul tags are joined into the tag label.
      '';

      allow_stale = mkOpt types.bool ''
        Allow stale Consul results
        (see <link xlink:href="https://www.consul.io/api/index.html#consistency-modes"/>).

        Will reduce load on Consul.
      '';

      refresh_interval = mkDefOpt types.str "30s" ''
        The time after which the provided names are refreshed.

        On large setup it might be a good idea to increase this value
        because the catalog will change all the time.
      '';
    };
  };

  promTypes.file_sd_config = types.submodule {
    options = {
      files = mkOption {
        type = types.listOf types.str;
        description = ''
          Patterns for files from which target groups are extracted. Refer
          to the Prometheus documentation for permitted filename patterns
          and formats.
        '';
      };

      refresh_interval = mkDefOpt types.str "5m" ''
        Refresh interval to re-read the files.
      '';
    };
  };

  promTypes.gce_sd_config = types.submodule {
    options = {
      # Use `mkOption` instead of `mkOpt` for project and zone because they are
      # required configuration values for `gce_sd_config`.
      project = mkOption {
        type = types.str;
        description = ''
          The GCP Project.
        '';
      };

      zone = mkOption {
        type = types.str;
        description = ''
          The zone of the scrape targets. If you need multiple zones use multiple
          gce_sd_configs.
        '';
      };

      filter = mkOpt types.str ''
        Filter can be used optionally to filter the instance list by other
        criteria Syntax of this filter string is described here in the filter
        query parameter section: <link
        xlink:href="https://cloud.google.com/compute/docs/reference/latest/instances/list"
        />.
      '';

      refresh_interval = mkDefOpt types.str "60s" ''
        Refresh interval to re-read the cloud instance list.
      '';

      port = mkDefOpt types.port "80" ''
        The port to scrape metrics from. If using the public IP address, this
        must instead be specified in the relabeling rule.
      '';

      tag_separator = mkDefOpt types.str "," ''
        The tag separator used to separate concatenated GCE instance network tags.

        See the GCP documentation on network tags for more information: <link
        xlink:href="https://cloud.google.com/vpc/docs/add-remove-network-tags"
        />
      '';
    };
  };

  promTypes.relabel_config = types.submodule {
    options = {
      source_labels = mkOpt (types.listOf types.str) ''
        The source labels select values from existing labels. Their content
        is concatenated using the configured separator and matched against
        the configured regular expression.
      '';

      separator = mkDefOpt types.str ";" ''
        Separator placed between concatenated source label values.
      '';

      target_label = mkOpt types.str ''
        Label to which the resulting value is written in a replace action.
        It is mandatory for replace actions.
      '';

      regex = mkDefOpt types.str "(.*)" ''
        Regular expression against which the extracted value is matched.
      '';

      modulus = mkOpt types.int ''
        Modulus to take of the hash of the source label values.
      '';

      replacement = mkDefOpt types.str "$1" ''
        Replacement value against which a regex replace is performed if the
        regular expression matches.
      '';

      action =
        mkDefOpt (types.enum ["replace" "keep" "drop" "hashmod" "labelmap" "labeldrop" "labelkeep"]) "replace" ''
        Action to perform based on regex matching.
      '';
    };
  };

  promTypes.tls_config = types.submodule {
    options = {
      ca_file = mkOpt types.str ''
        CA certificate to validate API server certificate with.
      '';

      cert_file = mkOpt types.str ''
        Certificate file for client cert authentication to the server.
      '';

      key_file = mkOpt types.str ''
        Key file for client cert authentication to the server.
      '';

      server_name = mkOpt types.str ''
        ServerName extension to indicate the name of the server.
        http://tools.ietf.org/html/rfc4366#section-3.1
      '';

      insecure_skip_verify = mkOpt types.bool ''
        Disable validation of the server certificate.
      '';
    };
  };

in {

  imports = [
    (mkRenamedOptionModule [ "services" "prometheus2" ] [ "services" "prometheus" ])
  ];

  options.services.prometheus = {

    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the Prometheus monitoring daemon.
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.prometheus;
      defaultText = literalExpression "pkgs.prometheus";
      description = ''
        The prometheus package that should be used.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 9090;
      description = ''
        Port to listen on.
      '';
    };

    listenAddress = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = ''
        Address to listen on for the web interface, API, and telemetry.
      '';
    };

    stateDir = mkOption {
      type = types.str;
      default = "prometheus2";
      description = ''
        Directory below <literal>/var/lib</literal> to store Prometheus metrics data.
        This directory will be created automatically using systemd's StateDirectory mechanism.
      '';
    };

    extraFlags = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Extra commandline options when launching Prometheus.
      '';
    };

    enableReload = mkOption {
      default = false;
      type = types.bool;
      description = ''
        Reload prometheus when configuration file changes (instead of restart).

        The following property holds: switching to a configuration
        (<literal>switch-to-configuration</literal>) that changes the prometheus
        configuration only finishes successully when prometheus has finished
        loading the new configuration.

        Note that prometheus will also get reloaded when the location of the
        <option>environmentFile</option> changes but not when its contents
        changes. So when you change it contents make sure to reload prometheus
        manually or include the hash of <option>environmentFile</option> in its
        name.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/root/prometheus.env";
      description = ''
        Environment file as defined in <citerefentry>
        <refentrytitle>systemd.exec</refentrytitle><manvolnum>5</manvolnum>
        </citerefentry>.

        Secrets may be passed to the service without adding them to the
        world-readable Nix store, by specifying placeholder variables as
        the option value in Nix and setting these variables accordingly in the
        environment file.

        Environment variables from this file will be interpolated into the
        config file using envsubst with this syntax:
        <literal>$ENVIRONMENT ''${VARIABLE}</literal>

        <programlisting>
          # Example scrape config entry handling an OAuth bearer token
          {
            job_name = "home_assistant";
            metrics_path = "/api/prometheus";
            scheme = "https";
            bearer_token = "\''${HOME_ASSISTANT_BEARER_TOKEN}";
            [...]
          }
        </programlisting>

        <programlisting>
          # Content of the environment file
          HOME_ASSISTANT_BEARER_TOKEN=someoauthbearertoken
        </programlisting>

        Note that this file needs to be available on the host on which
        <literal>Prometheus</literal> is running.
      '';
    };

    configText = mkOption {
      type = types.nullOr types.lines;
      default = null;
      description = ''
        If non-null, this option defines the text that is written to
        prometheus.yml. If null, the contents of prometheus.yml is generated
        from the structured config options.
      '';
    };

    globalConfig = mkOption {
      type = promTypes.globalConfig;
      default = {};
      description = ''
        Parameters that are valid in all  configuration contexts. They
        also serve as defaults for other configuration sections
      '';
    };

    remoteRead = mkOption {
      type = types.listOf promTypes.remote_read;
      default = [];
      description = ''
        Parameters of the endpoints to query from.
        See <link xlink:href="https://prometheus.io/docs/prometheus/latest/configuration/configuration/#remote_read">the official documentation</link> for more information.
      '';
    };

    remoteWrite = mkOption {
      type = types.listOf promTypes.remote_write;
      default = [];
      description = ''
        Parameters of the endpoints to send samples to.
        See <link xlink:href="https://prometheus.io/docs/prometheus/latest/configuration/configuration/#remote_write">the official documentation</link> for more information.
      '';
    };

    rules = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Alerting and/or Recording rules to evaluate at runtime.
      '';
    };

    ruleFiles = mkOption {
      type = types.listOf types.path;
      default = [];
      description = ''
        Any additional rules files to include in this configuration.
      '';
    };

    scrapeConfigs = mkOption {
      type = types.listOf promTypes.scrape_config;
      default = [];
      description = ''
        A list of scrape configurations.
      '';
    };

    alertmanagers = mkOption {
      type = types.listOf types.attrs;
      example = literalExpression ''
        [ {
          scheme = "https";
          path_prefix = "/alertmanager";
          static_configs = [ {
            targets = [
              "prometheus.domain.tld"
            ];
          } ];
        } ]
      '';
      default = [];
      description = ''
        A list of alertmanagers to send alerts to.
        See <link xlink:href="https://prometheus.io/docs/prometheus/latest/configuration/configuration/#alertmanager_config">the official documentation</link> for more information.
      '';
    };

    alertmanagerNotificationQueueCapacity = mkOption {
      type = types.int;
      default = 10000;
      description = ''
        The capacity of the queue for pending alert manager notifications.
      '';
    };

    alertmanagerTimeout = mkOption {
      type = types.int;
      default = 10;
      description = ''
        Alert manager HTTP API timeout (in seconds).
      '';
    };

    webExternalUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://example.com/";
      description = ''
        The URL under which Prometheus is externally reachable (for example,
        if Prometheus is served via a reverse proxy).
      '';
    };

    checkConfig = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Check configuration with <literal>promtool
        check</literal>. The call to <literal>promtool</literal> is
        subject to sandboxing by Nix. When credentials are stored in
        external files (<literal>password_file</literal>,
        <literal>bearer_token_file</literal>, etc), they will not be
        visible to <literal>promtool</literal> and it will report
        errors, despite a correct configuration.
      '';
    };

    retentionTime = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "15d";
      description = ''
        How long to retain samples in storage.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      ( let
          # Match something with dots (an IPv4 address) or something ending in
          # a square bracket (an IPv6 addresses) followed by a port number.
          legacy = builtins.match "(.*\\..*|.*]):([[:digit:]]+)" cfg.listenAddress;
        in {
          assertion = legacy == null;
          message = ''
            Do not specify the port for Prometheus to listen on in the
            listenAddress option; use the port option instead:
              services.prometheus.listenAddress = ${builtins.elemAt legacy 0};
              services.prometheus.port = ${builtins.elemAt legacy 1};
          '';
        }
      )
    ];

    users.groups.prometheus.gid = config.ids.gids.prometheus;
    users.users.prometheus = {
      description = "Prometheus daemon user";
      uid = config.ids.uids.prometheus;
      group = "prometheus";
    };
    systemd.services.prometheus = {
      wantedBy = [ "multi-user.target" ];
      after    = [ "network.target" ];
      preStart = mkIf (!cfg.enableReload) ''
         ${lib.getBin pkgs.envsubst}/bin/envsubst -o "/run/prometheus/prometheus-substituted.yaml" \
                                                  -i "${prometheusYml}"
      '';
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/prometheus" +
          optionalString (length cmdlineArgs != 0) (" \\\n  " +
            concatStringsSep " \\\n  " cmdlineArgs);
        ExecReload = mkIf cfg.enableReload "+${reload}/bin/reload-prometheus";
        User = "prometheus";
        Restart  = "always";
        EnvironmentFile = mkIf (cfg.environmentFile != null && !cfg.enableReload) [ cfg.environmentFile ];
        RuntimeDirectory = "prometheus";
        RuntimeDirectoryMode = "0700";
        WorkingDirectory = workingDir;
        StateDirectory = cfg.stateDir;
        StateDirectoryMode = "0700";
      };
    };
    systemd.services.prometheus-config-write = mkIf cfg.enableReload {
      wantedBy = [ "prometheus.service" ];
      before = [ "prometheus.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "prometheus";
        StateDirectory = cfg.stateDir;
        StateDirectoryMode = "0700";
        EnvironmentFile = mkIf (cfg.environmentFile != null) [ cfg.environmentFile ];
        ExecStart = "${writeConfig}/bin/write-prometheus-config";
      };
    };
    # prometheus-config-reload will activate after prometheus. However, what we
    # don't want is that on startup it immediately reloads prometheus because
    # prometheus itself might have just started.
    #
    # Instead we only want to reload prometheus when the config file has
    # changed. So on startup prometheus-config-reload will just output a
    # harmless message and then stay active (RemainAfterExit).
    #
    # Then, when the config file has changed, switch-to-configuration notices
    # that this service has changed and needs to be reloaded
    # (reloadIfChanged). The reload command then actually writes the new config
    # and reloads prometheus.
    systemd.services.prometheus-config-reload = mkIf cfg.enableReload {
      wantedBy = [ "prometheus.service" ];
      after = [ "prometheus.service" ];
      reloadIfChanged = true;
      serviceConfig = {
        Type = "oneshot";
        User = "prometheus";
        StateDirectory = cfg.stateDir;
        StateDirectoryMode = "0700";
        EnvironmentFile = mkIf (cfg.environmentFile != null) [ cfg.environmentFile ];
        RemainAfterExit = true;
        TimeoutSec = 60;
        ExecStart = "${pkgs.logger}/bin/logger 'prometheus-config-reload will only reload prometheus when reloaded itself.'";
        ExecReload = [
          "${writeConfig}/bin/write-prometheus-config"
          "+${triggerReload}/bin/trigger-reload-prometheus"
        ];
      };
    };
  };
}
