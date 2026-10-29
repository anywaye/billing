require "test_helper"

class CoreLocationTest < ActiveSupport::TestCase
  test "core is found from this checkout with nothing configured" do
    with_env("CORE_PATH" => nil, "CORE_SPECS_PATH" => nil) do
      core = TestSupport::CoreLocation.checkout

      assert core.present?, "core was not found from #{Dir.pwd}, and that is the BRK-4R2 hazard"

      assert File.directory?(core.join("schemas").to_s),
        "the resolved path has no schemas/ in it, so it is not core"
      assert File.file?(core.join("anywaye.yml").to_s),
        "the resolved path is not a anywaye checkout at all"
      assert File.file?(core.join("schemas", "event-envelope.schema.json").to_s),
        "the resolved path is core but has no envelope schema, which is what this tier reads first"
    end
  end

  test "a lookup that names nothing resolves nothing, not the working directory" do
    with_env("CORE_PATH" => nil, "CORE_SPECS_PATH" => nil) do
      simple_stubs.stub_object(TestSupport::CoreLocation, :primary_worktree) { nil }

      nothing = TestSupport::CoreLocation.checkout

      assert_not_equal Dir.pwd, nothing.to_s,
        "an empty worktree lookup resolved the working directory, which is a real directory and reads as found"
    end
  ensure
    simple_stubs.unstub_all!
  end

  test "what a worktree resolves is outside the worktree" do
    with_env("CORE_PATH" => nil, "CORE_SPECS_PATH" => nil) do
      core = TestSupport::CoreLocation.checkout.to_s

      assert_not core.start_with?("#{Rails.root}/"),
        "core resolved to something inside this checkout: #{core}"
    end
  end

  test "an explicit CORE_PATH is what the resolution answers, and it does not fall through" do
    core = TestSupport::CoreLocation.checkout

    assert core.present?, "no core checkout resolved, so this test has nothing to point at"

    assert_equal core.to_s, TestSupport::CoreLocation.checkout(core).to_s,
      "an explicit path was not honoured verbatim"

    assert_nil TestSupport::CoreLocation.checkout(Rails.root.join("..")),
      "an explicit path that is not core fell through to the implicit list " \
      "instead of being answered with nothing"
  end

  test "the CORE_PATH environment variable is the seam CI sets, and it is read" do
    core = TestSupport::CoreLocation.checkout

    assert core.present?

    with_env("CORE_PATH" => core.to_s, "CORE_SPECS_PATH" => nil) do
      assert_equal core.to_s, TestSupport::CoreLocation.checkout.to_s,
        "CORE_PATH was not read, so the seam CI's gate job uses does not work"
    end
  end

  test "a reader is handed a path even when there is no core, so its skip is reachable" do
    nowhere = Pathname.new("/nonexistent-core-checkout")

    simple_stubs.stub_object(TestSupport::CoreLocation, :checkout) { nil }
    simple_stubs.stub_object(TestSupport::CoreLocation, :searched) { [ nowhere ] }

    handed = TestSupport::CoreLocation.path_for

    assert handed.present?, "a reader was handed nil, which raises TypeError rather than skipping"
    assert_raises(Errno::ENOENT) do
      File.read(File.join(handed.to_s, "schemas", "event-envelope.schema.json"))
    end

    refute File.directory?(handed.to_s),
      "the fallback path exists, so a reader would find files in a directory that is not core"
  ensure
    simple_stubs.unstub_all!
  end

  test "a checkout with no core anywhere answers nil, which the callers read as nothing to check" do
    simple_stubs.stub_object(TestSupport::CoreLocation, :primary_worktree) { nil }
    simple_stubs.stub_object(TestSupport::CoreLocation, :readable?) { |_path| false }

    assert_nil TestSupport::CoreLocation.checkout,
      "nothing was found, and the resolution answered something anyway"
  ensure
    simple_stubs.unstub_all!
  end

  test "the paths the resolution tried are named, and the first is the sibling beside this checkout" do
    with_env("CORE_PATH" => nil, "CORE_SPECS_PATH" => nil) do
      searched = TestSupport::CoreLocation.searched

      assert_not_empty searched, "the resolution tried nowhere, so a skip message would name nothing"
      assert_equal Rails.root.join("..", "core").expand_path.to_s, searched.first.to_s
    end
  end

  test "the two readers that used to answer this alone both resolve core now" do
    with_env("CORE_PATH" => nil, "CORE_SPECS_PATH" => nil) do
      core = TestSupport::CoreLocation.checkout

      assert File.readable?(core.join("docs", "event-naming.md").to_s),
        "the catalog the delivery test reads is not at the resolved path"
      assert File.readable?(core.join("schemas", "event-envelope.schema.json").to_s),
        "the envelope schema the contract test reads is not at the resolved path"
    end
  end
end
