defmodule YmerNode.ExtraCaCertificates do
  @moduledoc """
  The CA certificates an operator adds to the ones the node's platform trusts,
  named by `path/0` and loaded at boot; every TLS connection the node makes
  trusts them alongside the platform's own.

  A node behind a proxy that re-signs TLS needs to trust a certificate its
  platform does not ship. Which one is the operator's alone to know, so the
  node carries none of its own: the operator names one PEM file, and this
  module puts its certificates into the VM-wide CA cache beside the
  platform's. Each should be a self-signed CA certificate, the one a chain
  ends at: Mint verifies a chain against the cache only up to a self-signed
  certificate, so an intermediate named here loads, and is logged, but
  anchors no chain.

  ## One cache, loaded once

  OTP keeps a single CA cache, `:public_key.cacerts_get/0`, and Mint reads it
  for every connection that passes no CA option of its own — every script
  request through `YmerNode.Script.Context.request/2`, the browser service
  client's calls, and any other request the node makes through Req or Mint.
  Loading the cache once, at boot, is what reaches every one of them with no
  per-caller code. A script that passes its own `:cacerts` or `:cacertfile`
  trusts only what it names: Mint uses the option in place of the cache, never
  beside it.

  A connection made outside Mint never reads the cache, so it does not trust
  the extra CA certificates. Typst's package downloads are one: Typst fetches a
  `@preview` package with its own TLS client, inside its native library, which
  trusts only the CA certificates compiled into it.

  `:public_key.cacerts_load/1` *replaces* the cache, and OTP has no call that
  adds to it, so the node combines. It loads the platform's CAs the
  platform's way, `:public_key.cacerts_load/0` — a bundle file on Linux, the
  system keychains on macOS — and then loads those certificates and the extra
  ones together, through one temporary PEM file it writes, loads and removes.
  The platform's set is never read from a file path of the node's choosing,
  so a host-run release on macOS trusts what its keychains hold, as it would
  without this module.

  The load is the application's first child, ahead of every child that can
  make a request: the cache fills itself lazily with the platform's CAs alone
  at the first connection that finds it empty, so a request made before the
  load would trust less than the operator named. With no file named the
  module does nothing, and the cache loads lazily as it always has.

  ## The file, and when it refuses boot

  The file must be a readable regular file of PEM blocks, every block a
  certificate that decodes, and at least one. Text outside the blocks is
  allowed — the `subject=` and `Bag Attributes` lines an export writes — and
  so are CRLF line endings. Anything else refuses boot, with one message per
  cause naming the setting, the path, what was found and its fix, each
  ending with the way to boot now: remove the setting.

  The node classifies the file itself rather than leaving it to OTP, whose
  own load cannot word a refusal: it answers `{:error, :enoent}` for a
  missing file, an empty one, a DER file and a key alike, and it loads the
  good certificates of a file with a damaged block beside them without a
  word. A node trusting part of what its operator named, silently, is worse
  than one that says which block broke. A key among the certificates usually
  means the wrong file was named, so it refuses too.

  An expired certificate, or one that is not a CA, is not refused: the
  operator chose it, and the handshake judges it as it judges any anchor.

  With a file named, the platform's own CAs failing to load refuses boot as
  well: trusting the extra certificates alone would leave every other host
  untrusted, and each connection to one would fail far from this cause. A
  successful load logs one line naming the file, how many certificates it
  added and each one's subject — what an operator checks in the node's boot
  log to see that the right file was read.
  """
  use GenServer

  require Logger
  require Record

  Record.defrecordp(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  @setting "`config :ymer_node, YmerNode.ExtraCaCertificates, :path`"

  @escape "Remove #{@setting} to boot on the platform's CAs alone."

  # One PEM block: its label, and everything up to the END line carrying the
  # same label — or, for a block that never closes, which
  # `:public_key.pem_decode/1` would raise on rather than answer, up to the next
  # BEGIN line or the end of the file, so the blocks after it are still counted.
  @block ~r/-----BEGIN ([^\r\n-]+)-----(.*?)(?:-----END \1-----|(?=-----BEGIN )|\z)/s

  # Short names for the attributes a CA certificate's subject usually carries;
  # any other attribute is written by its dotted OID.
  @attribute_names %{
    {2, 5, 4, 3} => "CN",
    {2, 5, 4, 6} => "C",
    {2, 5, 4, 7} => "L",
    {2, 5, 4, 8} => "ST",
    {2, 5, 4, 10} => "O",
    {2, 5, 4, 11} => "OU",
    {0, 9, 2342, 19_200_300, 100, 1, 25} => "DC",
    {1, 2, 840, 113_549, 1, 9, 1} => "emailAddress"
  }

  # ─── Runtime configuration ──────────────────────────────────────────

  @doc """
  The PEM file of extra CA certificates (`config :ymer_node,
  YmerNode.ExtraCaCertificates, :path`), returned as configured: an absolute
  path, which the configuration that runs the node expands, and `nil` when none
  is named.
  """
  def path do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:path)
  end

  # ─── Public API ─────────────────────────────────────────────────────

  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    case path() do
      nil ->
        :ignore

      path ->
        install!(path)
        :ignore
    end
  end

  @doc """
  Loads the platform's CAs and the extra CA certificates in `path` into the
  CA cache as one set, and logs one line naming what it added.

  Raises `ArgumentError`, carrying the message an operator reads in the boot
  log, when the file breaks the rule `read/1` checks — before the platform's
  CAs are touched — or when the platform's own CAs do not load.
  `load_platform` is that load, `:public_key.cacerts_load/0`; it is an
  argument only so a test can stand in a platform that fails.
  """
  def install!(path, load_platform \\ &:public_key.cacerts_load/0)
      when is_binary(path) and is_function(load_platform, 0) do
    extra =
      case read(path) do
        {:ok, extra} -> extra
        {:error, message} -> raise ArgumentError, message
      end

    case load_platform.() do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, platform_refusal(path, reason)
    end

    platform = Enum.map(:public_key.cacerts_get(), fn {:cert, der, _otp} -> der end)
    load_combined!(platform ++ extra)

    Logger.info(
      "extra CA certificates loaded from #{path}: " <>
        "#{length(extra)} — #{Enum.map_join(extra, "; ", &subject/1)}"
    )

    :ok
  end

  @doc """
  Reads the extra CA certificates in `path`: a readable regular file of PEM
  blocks, every block a certificate that decodes, and at least one.

  Answers each certificate's DER in file order, or `{:error, message}` with
  the refusal an operator reads — one message per cause, naming the variable,
  the path, what was found and its fix.
  """
  def read(path) when is_binary(path) do
    with {:ok, bytes} <- read_file(path) do
      certificates(path, bytes)
    end
  end

  @doc """
  The subject of the certificate `der`: each attribute as `<name>=<value>`, in
  the certificate's own order, joined by `, ` — the form
  `openssl x509 -noout -subject` prints for a subject of single-valued
  attributes. Values are written as they are, never escaped; the attributes
  of a multi-valued RDN are joined by `+`, an attribute with no short name is
  written by its dotted OID, and a value OTP does not decode is written as
  `#` and the hex of its DER, RFC 4514's form.
  """
  def subject(der) when is_binary(der) do
    otp_certificate(tbsCertificate: tbs) = :public_key.pkix_decode_cert(der, :otp)
    otp_tbs_certificate(subject: {:rdnSequence, rdns}) = tbs

    Enum.map_join(rdns, ", ", fn rdn -> Enum.map_join(rdn, "+", &attribute/1) end)
  end

  # ─── Private ────────────────────────────────────────────────────────

  defp read_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> read_regular(path)
      {:ok, %File.Stat{type: type}} -> {:error, not_a_file(path, type)}
      # :enotdir is a file where the path wants a directory: no file there either.
      {:error, reason} when reason in [:enoent, :enotdir] -> {:error, missing(path)}
      {:error, reason} -> {:error, unreadable(path, reason)}
    end
  end

  defp read_regular(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, unreadable(path, reason)}
    end
  end

  # No block at all is a file holding no PEM certificate — unless the whole
  # file decodes as one certificate, which is a DER export with its own fix.
  defp certificates(path, bytes) do
    case Regex.scan(@block, bytes) do
      [] -> {:error, if(der?(bytes), do: der(path), else: no_certificate(path))}
      blocks -> blocks |> Enum.map(&block/1) |> collect(path)
    end
  end

  defp block([whole, "CERTIFICATE", _body]) do
    if String.ends_with?(whole, "-----END CERTIFICATE-----"),
      do: certificate(whole),
      else: :undecodable
  end

  defp block([_whole, label, _body]), do: {:not_certificate, label}

  # The same test OTP's own load applies to a block, so a certificate this
  # accepts is one the cache will hold.
  defp certificate(whole) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(whole)
    _ = :public_key.pkix_decode_cert(der, :otp)
    {:ok, der}
  rescue
    _ -> :undecodable
  end

  defp der?(bytes) do
    _ = :public_key.pkix_decode_cert(bytes, :otp)
    true
  rescue
    _ -> false
  end

  # The first block that breaks the rule names the refusal, by its position.
  defp collect(results, path) do
    count = length(results)
    accepted = {:ok, for({:ok, der} <- results, do: der)}

    results
    |> Enum.with_index(1)
    |> Enum.find_value(accepted, fn
      {{:ok, _der}, _position} ->
        nil

      {:undecodable, position} ->
        {:error, undecodable(path, position, count)}

      {{:not_certificate, label}, position} ->
        {:error, not_certificate(path, position, count, label)}
    end)
  end

  defp load_combined!(ders) do
    file =
      Path.join(
        System.tmp_dir!(),
        "ymer-node-ca-certificates-#{System.os_time()}-#{System.unique_integer([:positive])}.pem"
      )

    pem = :public_key.pem_encode(Enum.map(ders, &{:Certificate, &1, :not_encrypted}))

    # Exclusive, so the file removed below is provably the one written here.
    File.write!(file, pem, [:exclusive])

    try do
      case :public_key.cacerts_load(file) do
        :ok -> :ok
        {:error, reason} -> raise "the combined CA set did not load: #{inspect(reason)}"
      end
    after
      File.rm(file)
    end
  end

  defp attribute({:AttributeTypeAndValue, oid, value}) do
    name = Map.get_lazy(@attribute_names, oid, fn -> oid |> Tuple.to_list() |> Enum.join(".") end)
    "#{name}=#{attribute_value(value)}"
  end

  defp attribute_value(value) when is_binary(value) or is_list(value), do: to_string(value)

  # A value the :otp decode leaves undecoded (organizationIdentifier, say) is
  # its DER, written as RFC 4514 writes one: `#` and the hex of the encoding.
  defp attribute_value({:asn1_OPENTYPE, der}) when is_binary(der),
    do: "#" <> Base.encode16(der, case: :lower)

  defp attribute_value({_string_type, value}) when is_binary(value) or is_list(value),
    do: to_string(value)

  defp attribute_value(value), do: inspect(value)

  defp missing(path) do
    "#{@setting} names no file: #{inspect(path)} does not exist. " <>
      "The path is read where the node runs, so name the file as the node sees it. " <>
      @escape
  end

  defp unreadable(path, reason) do
    "#{@setting} names a file the node cannot read: #{inspect(path)} " <>
      "(#{:file.format_error(reason)}). Make it readable by the user the node runs as. " <>
      @escape
  end

  defp not_a_file(path, :directory) do
    "#{@setting} names a directory, not a file: #{inspect(path)}. " <>
      "Name the PEM file itself. " <> @escape
  end

  defp not_a_file(path, _type) do
    "#{@setting} names something other than a regular file: #{inspect(path)}. " <>
      "Name the PEM file itself. " <> @escape
  end

  defp der(path) do
    "#{@setting} names a DER certificate, which the node does not read: #{inspect(path)}. " <>
      "Convert it to PEM with openssl x509 -inform der -in <file> -out <file>.pem " <>
      "and name the .pem file. " <> @escape
  end

  defp no_certificate(path) do
    "#{@setting} names a file holding no PEM certificate: #{inspect(path)} is empty, " <>
      "or holds no -----BEGIN CERTIFICATE----- block. " <>
      "Name a file of PEM certificates, the form an export writes them in. " <> @escape
  end

  # OpenSSL's own certificate forms: a certificate with trust settings
  # attached, and the older label. Neither is a plain certificate block.
  defp not_certificate(path, position, count, label)
       when label in ["TRUSTED CERTIFICATE", "X509 CERTIFICATE"] do
    "#{@setting} names a file whose block #{position} of #{count} is a #{label} block, " <>
      "OpenSSL's own form, not a plain certificate: #{inspect(path)}. " <>
      "Convert it with openssl x509 -in <file> -out <file>.pem and name the .pem file. " <>
      @escape
  end

  defp not_certificate(path, position, count, label) do
    "#{@setting} names a file whose block #{position} of #{count} is a #{label} block, " <>
      "not a certificate: #{inspect(path)}. The file may hold certificates only; " <>
      "a key there usually means the wrong file was named. " <> @escape
  end

  defp undecodable(path, position, count) do
    "#{@setting} names a file whose block #{position} of #{count} is a certificate " <>
      "that does not decode: #{inspect(path)}. The block is damaged or cut short; " <>
      "export the certificate again, or remove the block. " <> @escape
  end

  defp platform_refusal(path, reason) do
    "#{@setting} names #{inspect(path)}, but the platform's own CAs did not load " <>
      "(#{inspect(reason)}), " <>
      "and the extra CA certificates alone would leave every other host untrusted. " <>
      "Install the platform's CA certificates, such as Debian's ca-certificates package. " <>
      @escape
  end
end
