defmodule YmerNode.ExtraCaCertificatesTest do
  @moduledoc """
  Every case writes its file under its own `tmp_dir`, and the certificates
  are made at run time with `:public_key.pkix_test_root_cert/2`, so none is
  committed and none expires. That function's certificates carry OTP's fixed
  test subject, which is why the subject cases spell it out.

  **Not async**: the `install!/2` and `init/1` cases load the VM-wide CA
  cache, which every request the suite makes through Mint reads, and clear it
  on exit with `:public_key.cacerts_clear/0`, so the next connection loads the
  platform's set lazily, as a node with no file named does. The `init/1` cases
  also set this module's application env, and put back on exit what was there
  before. The info line a load logs sits below the suite's `:warning` level,
  so the case that reads it raises this module's own level for its duration.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YmerNode.ExtraCaCertificates

  @moduletag :tmp_dir

  @escape "Unset YMER_NODE_EXTRA_CA_CERTS to boot on the platform's CAs alone."

  @test_subject "emailAddress=root@example.org, CN=probe ca, L=Stockholm, C=SE, O=erlang, " <>
                  "OU=automated testing"

  @key "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"

  @corrupt "-----BEGIN CERTIFICATE-----\nAAAAbm90IGEgY2VydGlmaWNhdGU=\n-----END CERTIFICATE-----\n"

  defp certificate(name, options \\ []) do
    %{cert: der} = :public_key.pkix_test_root_cert(String.to_charlist(name), options)
    der
  end

  defp pem(ders), do: :public_key.pem_encode(Enum.map(ders, &{:Certificate, &1, :not_encrypted}))

  defp write(tmp_dir, name, bytes) do
    path = Path.join(tmp_dir, name)
    File.write!(path, bytes)
    path
  end

  # Every refusal names the path and ends with the same way to boot now.
  defp refusal!(path) do
    assert {:error, message} = ExtraCaCertificates.read(path)
    assert message =~ inspect(path)
    assert String.ends_with?(message, @escape)
    message
  end

  defp cache, do: Enum.map(:public_key.cacerts_get(), fn {:cert, der, _otp} -> der end)

  describe "read/1" do
    test "answers every certificate's DER, in file order", %{tmp_dir: tmp_dir} do
      first = certificate("first probe ca")
      second = certificate("second probe ca")
      path = write(tmp_dir, "two.pem", pem([first, second]))

      assert ExtraCaCertificates.read(path) == {:ok, [first, second]}
    end

    test "allows text outside the blocks, as an export writes it", %{tmp_dir: tmp_dir} do
      der = certificate("probe ca")
      noise = "Bag Attributes\n    friendlyName: probe\nsubject=CN=probe ca\n"
      path = write(tmp_dir, "exported.pem", noise <> pem([der]))

      assert ExtraCaCertificates.read(path) == {:ok, [der]}
    end

    test "reads CRLF line endings", %{tmp_dir: tmp_dir} do
      der = certificate("probe ca")
      path = write(tmp_dir, "crlf.pem", String.replace(pem([der]), "\n", "\r\n"))

      assert ExtraCaCertificates.read(path) == {:ok, [der]}
    end

    test "an expired certificate is not refused", %{tmp_dir: tmp_dir} do
      der = certificate("expired probe ca", validity: {{2020, 1, 1}, {2020, 1, 2}})
      path = write(tmp_dir, "expired.pem", pem([der]))

      assert ExtraCaCertificates.read(path) == {:ok, [der]}
    end

    @tag doc: """
         The likeliest mistake is a host path in the install's `.env`: the
         path is resolved inside the container, where it names nothing. A
         failure means the refusal stopped saying where the path is read, and
         the operator is left looking at a file that plainly exists on their
         own machine.
         """
    test "a path naming no file refuses, saying where the path is read", %{tmp_dir: tmp_dir} do
      message = refusal!(Path.join(tmp_dir, "absent.pem"))

      assert message =~ "YMER_NODE_EXTRA_CA_CERTS names no file inside the node"
      assert message =~ "keep the file under the /data mount, such as /data/extra-ca-certs.pem"
    end

    test "a path through a file refuses as naming no file", %{tmp_dir: tmp_dir} do
      file = write(tmp_dir, "plain", "")

      assert refusal!(Path.join(file, "extra.pem")) =~
               "YMER_NODE_EXTRA_CA_CERTS names no file inside the node"
    end

    test "an unreadable file refuses, naming why", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "unreadable.pem", pem([certificate("probe ca")]))
      File.chmod!(path, 0o000)

      message = refusal!(path)

      assert message =~ "names a file the node cannot read"
      assert message =~ "(permission denied)"
    end

    test "a directory refuses", %{tmp_dir: tmp_dir} do
      message = refusal!(tmp_dir)

      assert message =~ "names a directory, not a file"
      assert message =~ "Name the PEM file itself."
    end

    test "a DER certificate refuses, with the openssl line that converts it", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "probe.der", certificate("probe ca"))

      message = refusal!(path)

      assert message =~ "names a DER certificate"
      assert message =~ "openssl x509 -inform der -in <file> -out <file>.pem"
    end

    test "an empty file, or one of other text, refuses as holding no PEM certificate", %{
      tmp_dir: tmp_dir
    } do
      for {name, bytes} <- [{"empty.pem", ""}, {"text.pem", "hello\n"}] do
        message = refusal!(write(tmp_dir, name, bytes))

        assert message =~ "names a file holding no PEM certificate"
      end
    end

    @tag doc: """
         A key beside the certificates usually means the operator named the
         wrong file. OTP's own load skips such a block with a warning and
         trusts the rest; a failure here means the node does the same.
         """
    test "a block that is not a certificate refuses, naming its position and label", %{
      tmp_dir: tmp_dir
    } do
      path = write(tmp_dir, "with-key.pem", pem([certificate("probe ca")]) <> @key)

      assert refusal!(path) =~ "block 2 of 2 is a PRIVATE KEY block, not a certificate"

      key_only = write(tmp_dir, "key.pem", @key)
      assert refusal!(key_only) =~ "block 1 of 1 is a PRIVATE KEY block, not a certificate"
    end

    test "OpenSSL's own certificate forms refuse, with the openssl line that converts them", %{
      tmp_dir: tmp_dir
    } do
      for label <- ["TRUSTED CERTIFICATE", "X509 CERTIFICATE"] do
        bytes = "-----BEGIN #{label}-----\nAAAA\n-----END #{label}-----\n"
        message = refusal!(write(tmp_dir, "openssl.pem", bytes))

        assert message =~ "block 1 of 1 is a #{label} block, OpenSSL's own form"
        assert message =~ "openssl x509 -in <file> -out <file>.pem"
        refute message =~ "a key there"
      end
    end

    @tag doc: """
         OTP's own load drops a certificate block that does not decode
         silently — no warning — and trusts the good ones beside it. A failure
         here means a damaged file boots a node trusting part of what its
         operator named, with nothing in the log to say so.
         """
    test "a certificate that does not decode refuses, naming its position among good ones", %{
      tmp_dir: tmp_dir
    } do
      bytes =
        pem([certificate("first probe ca")]) <> @corrupt <> pem([certificate("third probe ca")])

      path = write(tmp_dir, "damaged.pem", bytes)

      assert refusal!(path) =~ "block 2 of 3 is a certificate that does not decode"
    end

    test "a file whose only block is a certificate that does not decode refuses", %{
      tmp_dir: tmp_dir
    } do
      path = write(tmp_dir, "corrupt.pem", @corrupt)

      assert refusal!(path) =~ "block 1 of 1 is a certificate that does not decode"
    end

    test "a certificate block that never closes refuses as one that does not decode", %{
      tmp_dir: tmp_dir
    } do
      bytes = pem([certificate("probe ca")]) <> "-----BEGIN CERTIFICATE-----\nAAAA\n"
      path = write(tmp_dir, "cut-short.pem", bytes)

      assert refusal!(path) =~ "block 2 of 2 is a certificate that does not decode"
    end

    @tag doc: """
         A block that never closes ends, as the scanner reads it, at the next
         BEGIN line. A failure means the broken block swallowed the good one
         after it: the refusal miscounts the file's blocks, or the merged
         block decoded and a file with a damaged block in its middle boots
         trusting the rest.
         """
    test "a certificate block that never closes, before a good one, still refuses", %{
      tmp_dir: tmp_dir
    } do
      unclosed = "-----BEGIN CERTIFICATE-----\nAAAA\n"

      bytes =
        pem([certificate("first probe ca")]) <> unclosed <> pem([certificate("third probe ca")])

      path = write(tmp_dir, "unclosed-middle.pem", bytes)

      assert refusal!(path) =~ "block 2 of 3 is a certificate that does not decode"
    end
  end

  describe "subject/1" do
    test "prints each attribute in the certificate's own order, as openssl does" do
      assert ExtraCaCertificates.subject(certificate("probe ca")) == @test_subject
    end

    @tag doc: """
         OTP leaves some subject attributes undecoded — organizationIdentifier
         among them — and answers their DER. A failure means those bytes,
         tag and length included, are written into the boot line as text.
         """
    test "writes a value OTP does not decode as # and the hex of its DER" do
      %{cert: der, key: key} = :public_key.pkix_test_root_cert(~c"probe ca", [])
      {:OTPCertificate, tbs, _algorithm, _signature} = :public_key.pkix_decode_cert(der, :otp)
      {:rdnSequence, rdns} = elem(tbs, 6)
      organization_identifier = {2, 5, 4, 97}
      value = {:asn1_OPENTYPE, <<0x0C, 3, "abc">>}
      name = {:rdnSequence, rdns ++ [[{:AttributeTypeAndValue, organization_identifier, value}]]}
      # The subject sits at position 6 of the TBS record, the issuer at 4.
      signed = :public_key.pkix_sign(tbs |> put_elem(6, name) |> put_elem(4, name), key)

      assert ExtraCaCertificates.subject(signed) == @test_subject <> ", 2.5.4.97=#0c03616263"
    end
  end

  describe "install!/2" do
    setup do
      on_exit(fn -> :public_key.cacerts_clear() end)
    end

    test "loads the platform's CAs and the extra ones as one set, and logs what it added", %{
      tmp_dir: tmp_dir
    } do
      der = certificate("probe ca")
      path = write(tmp_dir, "extra.pem", pem([der]))
      Logger.put_module_level(ExtraCaCertificates, :info)
      on_exit(fn -> Logger.delete_module_level(ExtraCaCertificates) end)

      log =
        capture_log([level: :info], fn -> assert ExtraCaCertificates.install!(path) == :ok end)

      combined = cache()
      assert :public_key.cacerts_load() == :ok
      platform = cache()

      assert der in combined
      assert length(combined) == length(platform) + 1

      assert log =~
               "extra CA certificates loaded from #{path} (YMER_NODE_EXTRA_CA_CERTS): 1 — " <>
                 @test_subject
    end

    test "a refused file raises before the platform's CAs are touched", %{tmp_dir: tmp_dir} do
      platform = fn ->
        send(self(), :platform_loaded)
        :ok
      end

      assert_raise ArgumentError, ~r/names no file inside the node/, fn ->
        ExtraCaCertificates.install!(Path.join(tmp_dir, "absent.pem"), platform)
      end

      refute_received :platform_loaded
    end

    @tag doc: """
         With the variable set, trusting the extra certificates alone would
         leave every other host untrusted. A failure means a node whose
         platform has no CAs boots anyway, and every connection to a public
         host fails with `Unknown CA`, far from this cause.
         """
    test "the platform's CAs failing to load refuses boot, though the file is good", %{
      tmp_dir: tmp_dir
    } do
      path = write(tmp_dir, "extra.pem", pem([certificate("probe ca")]))

      error =
        assert_raise ArgumentError, fn ->
          ExtraCaCertificates.install!(path, fn -> {:error, :no_cacerts_found} end)
        end

      assert error.message =~ "YMER_NODE_EXTRA_CA_CERTS is set to #{inspect(path)}"
      assert error.message =~ "the platform's own CAs did not load (:no_cacerts_found)"
      assert String.ends_with?(error.message, @escape)
    end

    test "leaves no temporary file behind", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "extra.pem", pem([certificate("probe ca")]))
      pattern = Path.join(System.tmp_dir!(), "ymer-node-ca-certificates-*")
      before = Path.wildcard(pattern)

      assert ExtraCaCertificates.install!(path) == :ok

      assert Path.wildcard(pattern) == before
    end
  end

  describe "init/1" do
    setup do
      saved = Application.fetch_env(:ymer_node, ExtraCaCertificates)

      on_exit(fn ->
        case saved do
          {:ok, value} -> Application.put_env(:ymer_node, ExtraCaCertificates, value)
          :error -> Application.delete_env(:ymer_node, ExtraCaCertificates)
        end

        :public_key.cacerts_clear()
      end)
    end

    test "with no file named it loads nothing and steps aside" do
      Application.delete_env(:ymer_node, ExtraCaCertificates)

      assert ExtraCaCertificates.path() == nil
      assert ExtraCaCertificates.init([]) == :ignore
    end

    @tag doc: """
         The child is where the configured path meets the load. A failure
         means the node boots without the certificates its operator named:
         the child stopped reading the key `config/runtime.exs` writes, or
         stopped loading the file it names.
         """
    test "loads the file the config names, then steps aside", %{tmp_dir: tmp_dir} do
      der = certificate("probe ca")
      path = write(tmp_dir, "extra.pem", pem([der]))
      Application.put_env(:ymer_node, ExtraCaCertificates, path: path)

      assert ExtraCaCertificates.path() == path
      assert ExtraCaCertificates.init([]) == :ignore

      combined = cache()
      assert :public_key.cacerts_load() == :ok
      platform = cache()

      assert der in combined
      assert length(combined) == length(platform) + 1
    end

    @tag doc: """
         A raise here fails the application's first child, so the node
         refuses boot and the log carries the message. A failure means a
         file the node cannot use no longer stops it booting.
         """
    test "a file the config names that the node cannot use raises", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "absent.pem")
      Application.put_env(:ymer_node, ExtraCaCertificates, path: path)

      assert_raise ArgumentError, ~r/names no file inside the node/, fn ->
        ExtraCaCertificates.init([])
      end
    end
  end
end
