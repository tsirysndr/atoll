{ lib, beamPackages, overrides ? (x: y: {}) }:

let
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildErlangMk = lib.makeOverridable beamPackages.buildErlangMk;

  self = packages // (overrides self packages);

  packages = with beamPackages; with self; {
    acceptor_pool = buildRebar3 rec {
      name = "acceptor_pool";
      version = "1.0.1";

      src = fetchHex {
        pkg = "acceptor_pool";
        version = "${version}";
        sha256 = "f172f3d74513e8edd445c257d596fc84dbdd56d2c6fa287434269648ae5a421e";
      };

      beamDeps = [];
    };

    argon2_elixir = buildMix rec {
      name = "argon2_elixir";
      version = "4.1.3";

      src = fetchHex {
        pkg = "argon2_elixir";
        version = "${version}";
        sha256 = "7c295b8d8e0eaf6f43641698f962526cdf87c6feb7d14bd21e599271b510608c";
      };

      beamDeps = [ comeonin elixir_make ];
    };

    bandit = buildMix rec {
      name = "bandit";
      version = "1.12.5";

      src = fetchHex {
        pkg = "bandit";
        version = "${version}";
        sha256 = "c5684ca062fa407cac115aec3256383f3e2ec9fdced7904d59cf5a7bb7ed6181";
      };

      beamDeps = [ hpax plug telemetry thousand_island websock ];
    };

    cc_precompiler = buildMix rec {
      name = "cc_precompiler";
      version = "0.1.11";

      src = fetchHex {
        pkg = "cc_precompiler";
        version = "${version}";
        sha256 = "3427232caf0835f94680e5bcf082408a70b48ad68a5f5c0b02a3bea9f3a075b9";
      };

      beamDeps = [ elixir_make ];
    };

    chatterbox = buildRebar3 rec {
      name = "chatterbox";
      version = "0.16.0";

      src = fetchHex {
        pkg = "ts_chatterbox";
        version = "${version}";
        sha256 = "34c145c702f3a8d22f49a189eb34579ef3db68f9a98a82d19b5cf6e390aad54f";
      };

      beamDeps = [ hpack ];
    };

    comeonin = buildMix rec {
      name = "comeonin";
      version = "5.5.1";

      src = fetchHex {
        pkg = "comeonin";
        version = "${version}";
        sha256 = "65aac8f19938145377cee73973f192c5645873dcf550a8a6b18187d17c13ccdb";
      };

      beamDeps = [];
    };

    ctx = buildRebar3 rec {
      name = "ctx";
      version = "0.6.0";

      src = fetchHex {
        pkg = "ctx";
        version = "${version}";
        sha256 = "a14ed2d1b67723dbebbe423b28d7615eb0bdcba6ff28f2d1f1b0a7e1d4aa5fc2";
      };

      beamDeps = [];
    };

    db_connection = buildMix rec {
      name = "db_connection";
      version = "2.10.2";

      src = fetchHex {
        pkg = "db_connection";
        version = "${version}";
        sha256 = "510b14482330f1af6490a2fa0efd8d4f1435d1529b165647df22ac0f2df0fa93";
      };

      beamDeps = [ telemetry ];
    };

    decimal = buildMix rec {
      name = "decimal";
      version = "3.1.1";

      src = fetchHex {
        pkg = "decimal";
        version = "${version}";
        sha256 = "c5f25f2ced74a0587d03e6023f595db8e924c9d3922c8c8ffd9edfc4498cf1f6";
      };

      beamDeps = [];
    };

    dns_cluster = buildMix rec {
      name = "dns_cluster";
      version = "0.2.0";

      src = fetchHex {
        pkg = "dns_cluster";
        version = "${version}";
        sha256 = "ba6f1893411c69c01b9e8e8f772062535a4cf70f3f35bcc964a324078d8c8240";
      };

      beamDeps = [];
    };

    ecto = buildMix rec {
      name = "ecto";
      version = "3.14.2";

      src = fetchHex {
        pkg = "ecto";
        version = "${version}";
        sha256 = "25d60b8c816a07d19d85b80bdf60978bd8b102209dda198d768cd7c6745339a6";
      };

      beamDeps = [ decimal jason telemetry ];
    };

    ecto_sql = buildMix rec {
      name = "ecto_sql";
      version = "3.14.0";

      src = fetchHex {
        pkg = "ecto_sql";
        version = "${version}";
        sha256 = "f4d8d36faf294c9417b5a37ec7ac8217ee2abdef5fcf197ba690f361548d3949";
      };

      beamDeps = [ db_connection decimal ecto postgrex telemetry ];
    };

    ecto_sqlite3 = buildMix rec {
      name = "ecto_sqlite3";
      version = "0.25.0";

      src = fetchHex {
        pkg = "ecto_sqlite3";
        version = "${version}";
        sha256 = "7da65c7af38dccf228320db32f93ae49650b0afdd850a09fd2fb191554b3faf5";
      };

      beamDeps = [ decimal ecto ecto_sql exqlite ];
    };

    elixir_make = buildMix rec {
      name = "elixir_make";
      version = "0.10.0";

      src = fetchHex {
        pkg = "elixir_make";
        version = "${version}";
        sha256 = "dc1f09fb7fa68866b886abd5f0f3c83553b1a19a52359a899e92af1bb3b31982";
      };

      beamDeps = [];
    };

    exqlite = buildMix rec {
      name = "exqlite";
      version = "0.41.0";

      src = fetchHex {
        pkg = "exqlite";
        version = "${version}";
        sha256 = "a7e9b6bed529ab72aa07ed2a925ac109c27e6877a7a8af252361c396a4192855";
      };

      beamDeps = [ cc_precompiler db_connection elixir_make ];
    };

    finch = buildMix rec {
      name = "finch";
      version = "0.23.0";

      src = fetchHex {
        pkg = "finch";
        version = "${version}";
        sha256 = "80e58d3f936f57e3fdf404f83a3642897ae6d9fb642934e46da4d8fe761b99d5";
      };

      beamDeps = [ mime mint nimble_options nimble_pool telemetry ];
    };

    gproc = buildRebar3 rec {
      name = "gproc";
      version = "1.2.0";

      src = fetchHex {
        pkg = "gproc";
        version = "${version}";
        sha256 = "70c6f8c91fa5974296cd87974949d8eab953230414f31c4a623ff75131e0827a";
      };

      beamDeps = [];
    };

    grpcbox = buildRebar3 rec {
      name = "grpcbox";
      version = "0.18.0";

      src = fetchHex {
        pkg = "grpcbox";
        version = "${version}";
        sha256 = "5ec9f8fe664ab51201b32c117a61511a1f9d6316771e3891ba8a88d289a732ab";
      };

      beamDeps = [ acceptor_pool chatterbox ctx gproc ];
    };

    hpack = buildRebar3 rec {
      name = "hpack";
      version = "0.3.0";

      src = fetchHex {
        pkg = "hpack_erl";
        version = "${version}";
        sha256 = "d6137d7079169d8c485c6962dfe261af5b9ef60fbc557344511c1e65e3d95fb0";
      };

      beamDeps = [];
    };

    hpax = buildMix rec {
      name = "hpax";
      version = "1.1.0";

      src = fetchHex {
        pkg = "hpax";
        version = "${version}";
        sha256 = "0b8d0f05832f55571d65ac720f79bf8994138ffbb133209dc4685eae0ad456a8";
      };

      beamDeps = [];
    };

    jason = buildMix rec {
      name = "jason";
      version = "1.4.5";

      src = fetchHex {
        pkg = "jason";
        version = "${version}";
        sha256 = "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684";
      };

      beamDeps = [ decimal ];
    };

    jose = buildMix rec {
      name = "jose";
      version = "1.11.12";

      src = fetchHex {
        pkg = "jose";
        version = "${version}";
        sha256 = "31e92b653e9210b696765cdd885437457de1add2a9011d92f8cf63e4641bab7b";
      };

      beamDeps = [];
    };

    mime = buildMix rec {
      name = "mime";
      version = "2.0.7";

      src = fetchHex {
        pkg = "mime";
        version = "${version}";
        sha256 = "6171188e399ee16023ffc5b76ce445eb6d9672e2e241d2df6050f3c771e80ccd";
      };

      beamDeps = [];
    };

    mint = buildMix rec {
      name = "mint";
      version = "1.10.1";

      src = fetchHex {
        pkg = "mint";
        version = "${version}";
        sha256 = "0ba2a904605ed8406393444fb8b3356dc58eb59ee6c7fb94ac3f015e1be129e8";
      };

      beamDeps = [ hpax ];
    };

    nimble_options = buildMix rec {
      name = "nimble_options";
      version = "1.1.1";

      src = fetchHex {
        pkg = "nimble_options";
        version = "${version}";
        sha256 = "821b2470ca9442c4b6984882fe9bb0389371b8ddec4d45a9504f00a66f650b44";
      };

      beamDeps = [];
    };

    nimble_pool = buildMix rec {
      name = "nimble_pool";
      version = "1.1.0";

      src = fetchHex {
        pkg = "nimble_pool";
        version = "${version}";
        sha256 = "af2e4e6b34197db81f7aad230c1118eac993acc0dae6bc83bac0126d4ae0813a";
      };

      beamDeps = [];
    };

    opentelemetry = buildRebar3 rec {
      name = "opentelemetry";
      version = "1.7.0";

      src = fetchHex {
        pkg = "opentelemetry";
        version = "${version}";
        sha256 = "a9173b058c4549bf824cbc2f1d2fa2adc5cdedc22aa3f0f826951187bbd53131";
      };

      beamDeps = [ opentelemetry_api ];
    };

    opentelemetry_api = buildMix rec {
      name = "opentelemetry_api";
      version = "1.5.0";

      src = fetchHex {
        pkg = "opentelemetry_api";
        version = "${version}";
        sha256 = "f53ec8a1337ae4a487d43ac89da4bd3a3c99ddf576655d071deed8b56a2d5dda";
      };

      beamDeps = [];
    };

    opentelemetry_api_experimental = buildMix rec {
      name = "opentelemetry_api_experimental";
      version = "0.6.0";

      src = fetchHex {
        pkg = "opentelemetry_api_experimental";
        version = "${version}";
        sha256 = "8a4d5902034e95a1eda09575c4e9902245f16dac1c08c7b0cc0b1f7c593ce56a";
      };

      beamDeps = [ opentelemetry_api ];
    };

    opentelemetry_experimental = buildRebar3 rec {
      name = "opentelemetry_experimental";
      version = "0.6.0";

      src = fetchHex {
        pkg = "opentelemetry_experimental";
        version = "${version}";
        sha256 = "01483c4dfc46044e8f2f3955a5d372765fd3e2584a9ad05ac81a8e495029919e";
      };

      beamDeps = [ opentelemetry opentelemetry_api opentelemetry_api_experimental ];
    };

    opentelemetry_exporter = buildRebar3 rec {
      name = "opentelemetry_exporter";
      version = "1.11.0";

      src = fetchHex {
        pkg = "opentelemetry_exporter";
        version = "${version}";
        sha256 = "24833c5f54d0996a454793383a5a8526750cbacc5c03e5be54b593fe7d47fb0a";
      };

      beamDeps = [ grpcbox opentelemetry opentelemetry_api tls_certificate_check ];
    };

    phoenix = buildMix rec {
      name = "phoenix";
      version = "1.8.15";

      src = fetchHex {
        pkg = "phoenix";
        version = "${version}";
        sha256 = "7b83ed6b3d544f24a29277eab7f051be38b76f390bb511bb6ddb7ec6e8e05b95";
      };

      beamDeps = [ bandit jason phoenix_pubsub phoenix_template plug plug_crypto telemetry websock_adapter ];
    };

    phoenix_ecto = buildMix rec {
      name = "phoenix_ecto";
      version = "4.7.0";

      src = fetchHex {
        pkg = "phoenix_ecto";
        version = "${version}";
        sha256 = "1d75011e4254cb4ddf823e81823a9629559a1be93b4321a6a5f11a5306fbf4cc";
      };

      beamDeps = [ ecto plug postgrex ];
    };

    phoenix_pubsub = buildMix rec {
      name = "phoenix_pubsub";
      version = "2.3.0";

      src = fetchHex {
        pkg = "phoenix_pubsub";
        version = "${version}";
        sha256 = "eec7be6e9cf02e2551d389b558402d6c637cd3973796326e7ba4bb03c6b2e91d";
      };

      beamDeps = [];
    };

    phoenix_template = buildMix rec {
      name = "phoenix_template";
      version = "1.1.0";

      src = fetchHex {
        pkg = "phoenix_template";
        version = "${version}";
        sha256 = "eba70070de79b2c3501ef205a74a69f98ab352f3785aa15da9ed161f9fe0fd5d";
      };

      beamDeps = [];
    };

    plug = buildMix rec {
      name = "plug";
      version = "1.20.3";

      src = fetchHex {
        pkg = "plug";
        version = "${version}";
        sha256 = "be266aee1b8536ef6409d58cf39a3121319f0ec47cfa1b24024485aa0e76ad76";
      };

      beamDeps = [ mime plug_crypto telemetry ];
    };

    plug_crypto = buildMix rec {
      name = "plug_crypto";
      version = "2.2.0";

      src = fetchHex {
        pkg = "plug_crypto";
        version = "${version}";
        sha256 = "83a95744ab1c75876542b6fab135fcc176280e0f301a111c1f757fddcec95d2c";
      };

      beamDeps = [];
    };

    postgrex = buildMix rec {
      name = "postgrex";
      version = "0.22.4";

      src = fetchHex {
        pkg = "postgrex";
        version = "${version}";
        sha256 = "4aae45a2d60e35b04eea2602440be152fae332901f1fc7a60fc7cb7f0f9a9c5a";
      };

      beamDeps = [ db_connection decimal jason ];
    };

    redix = buildMix rec {
      name = "redix";
      version = "1.9.2";

      src = fetchHex {
        pkg = "redix";
        version = "${version}";
        sha256 = "02b0b644de27d9f25d3664e6bb7c11ee150255930f08a362655dd8aba9b0a6a1";
      };

      beamDeps = [ nimble_options telemetry ];
    };

    req = buildMix rec {
      name = "req";
      version = "0.7.4";

      src = fetchHex {
        pkg = "req";
        version = "${version}";
        sha256 = "4b192d63253e8dcc6221ef992ea9ebef7d3555166e8423aa5b553e86bc3c69a2";
      };

      beamDeps = [ finch jason mime plug ];
    };

    ssl_verify_fun = buildRebar3 rec {
      name = "ssl_verify_fun";
      version = "1.1.7";

      src = fetchHex {
        pkg = "ssl_verify_fun";
        version = "${version}";
        sha256 = "fe4c190e8f37401d30167c8c405eda19469f34577987c76dde613e838bbc67f8";
      };

      beamDeps = [];
    };

    telemetry = buildRebar3 rec {
      name = "telemetry";
      version = "1.4.2";

      src = fetchHex {
        pkg = "telemetry";
        version = "${version}";
        sha256 = "928f6495066506077862c0d1646609eed891a4326bee3126ba54b60af61febb1";
      };

      beamDeps = [];
    };

    telemetry_metrics = buildMix rec {
      name = "telemetry_metrics";
      version = "1.2.0";

      src = fetchHex {
        pkg = "telemetry_metrics";
        version = "${version}";
        sha256 = "71dde12fc29b58b9c77ec17ec319109e5ca848d010fc1965ed4463bba1837c07";
      };

      beamDeps = [ telemetry ];
    };

    telemetry_poller = buildRebar3 rec {
      name = "telemetry_poller";
      version = "1.3.0";

      src = fetchHex {
        pkg = "telemetry_poller";
        version = "${version}";
        sha256 = "51f18bed7128544a50f75897db9974436ea9bfba560420b646af27a9a9b35211";
      };

      beamDeps = [ telemetry ];
    };

    thousand_island = buildMix rec {
      name = "thousand_island";
      version = "1.5.0";

      src = fetchHex {
        pkg = "thousand_island";
        version = "${version}";
        sha256 = "708923d40523e43cf99041ab37a0d4b0ec426ac6438fa3716ab23d919eaeb412";
      };

      beamDeps = [ telemetry ];
    };

    tls_certificate_check = buildRebar3 rec {
      name = "tls_certificate_check";
      version = "1.35.0";

      src = fetchHex {
        pkg = "tls_certificate_check";
        version = "${version}";
        sha256 = "36fd91d635761daffa12e75b0c784b24510a69ad53348b8276a553d2d665b579";
      };

      beamDeps = [ ssl_verify_fun ];
    };

    websock = buildMix rec {
      name = "websock";
      version = "0.5.3";

      src = fetchHex {
        pkg = "websock";
        version = "${version}";
        sha256 = "6105453d7fac22c712ad66fab1d45abdf049868f253cf719b625151460b8b453";
      };

      beamDeps = [];
    };

    websock_adapter = buildMix rec {
      name = "websock_adapter";
      version = "0.6.0";

      src = fetchHex {
        pkg = "websock_adapter";
        version = "${version}";
        sha256 = "50021a85bce8f203b086705d9e0c5415e2c7eb05d319111b0428fe71f9934617";
      };

      beamDeps = [ bandit plug websock ];
    };
  };
in self

