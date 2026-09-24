<#
    Lab-Relay settings. This file is public - it holds no secrets.
    The GitHub App client ID is public by design; device flow needs no client secret.
#>
@{
    # --- GitHub ------------------------------------------------------------------
    Owner                 = 'Don-Paterson'
    CodeRepo              = 'Lab-Relay'            # public: this code, fetched by irm | iex
    ChannelRepo           = 'Lab-Relay-Channel'    # private: jobs and results
    Branch                = 'main'
    AppClientId           = 'Iv23liW99Woo8kRBZE5p' # GitHub App "Lab-Relay-app" (device flow)

    # --- timing ------------------------------------------------------------------
    PollSeconds           = 30     # how often each side checks the channel
    OutboxCheckSeconds    = 2      # how often the laptop looks in outbox\
    StableSeconds         = 3      # a file must be unchanged this long before it is sent
    DefaultTimeoutSeconds = 600    # per job; override with  # relay: timeout=1800
    MaxTimeoutSeconds     = 7200
    StaleJobMinutes       = 60     # a new lab session ignores unclaimed jobs older than this

    # --- limits ------------------------------------------------------------------
    MaxOutputBytes        = 5MB    # output.txt is truncated (head + tail) above this
    MaxFileBytes          = 25MB   # any single returned file
    JobExtensions         = @('.ps1')
    ResultExtensions      = @('.txt', '.log', '.json', '.csv', '.xml', '.png', '.jpg')

    # --- housekeeping ------------------------------------------------------------
    CompactThresholdMB    = 50     # laptop squashes channel history above this
    CompactKeepDays       = 7

    # --- TLS guard (lab) ---------------------------------------------------------
    # The lab refuses to authenticate unless every GitHub host presents a certificate
    # issued by one of these. Guards against the upstream FortiGate starting to inspect GitHub.
    TlsHosts              = @('github.com', 'api.github.com', 'raw.githubusercontent.com')
    TrustedIssuerOrgs     = @('DigiCert Inc', 'Sectigo Limited', "Let's Encrypt", 'GlobalSign nv-sa', 'Microsoft Corporation')
}
