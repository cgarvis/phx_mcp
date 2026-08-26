defmodule MCP.URITemplateTest do
  use ExUnit.Case, async: true

  alias MCP.URITemplate

  test "matches a single variable and percent-decodes it" do
    t = URITemplate.compile!("app://items/{id}")

    assert URITemplate.match(t, "app://items/42") == {:ok, %{"id" => "42"}}
    assert URITemplate.match(t, "app://items/a%20b") == {:ok, %{"id" => "a b"}}
  end

  test "a variable never crosses a slash and never matches empty" do
    t = URITemplate.compile!("app://items/{id}")

    assert URITemplate.match(t, "app://items/1/2") == :nomatch
    assert URITemplate.match(t, "app://items/") == :nomatch
    assert URITemplate.match(t, "app://other/1") == :nomatch
  end

  # The slash check runs on the raw span, so %2F would smuggle one past it.
  test "a value that decodes to a slash or invalid UTF-8 does not match" do
    t = URITemplate.compile!("app://items/{id}")

    assert URITemplate.match(t, "app://items/a%2Fb") == :nomatch
    assert URITemplate.match(t, "app://items/%2F") == :nomatch
    assert URITemplate.match(t, "app://items/%FF") == :nomatch
  end

  test "matches multiple variables split by literals" do
    t = URITemplate.compile!("app://m/{a}/notes/{b}")

    assert URITemplate.match(t, "app://m/1/notes/2") == {:ok, %{"a" => "1", "b" => "2"}}
    assert URITemplate.match(t, "app://m/1/other/2") == :nomatch
  end

  test "greedy matching backtracks so trailing literals still match" do
    t = URITemplate.compile!("app://v{major}.{minor}")

    assert URITemplate.match(t, "app://v1.2.3") == {:ok, %{"major" => "1.2", "minor" => "3"}}
  end

  test "compile! rejects malformed or variable-free templates" do
    for bad <- [
          "app://items/{id",
          "app://items/{id!}",
          "app://items/{}",
          "app://{a}/{a}",
          "app://}{a}",
          "app://static"
        ] do
      assert_raise ArgumentError, fn -> URITemplate.compile!(bad) end
    end
  end

  describe "reserved expansion ({+var})" do
    test "claims a multi-segment value, slashes included" do
      t = URITemplate.compile!("app://files/{+path}")

      assert URITemplate.match(t, "app://files/reports/2026-08-25.md") ==
               {:ok, %{"path" => "reports/2026-08-25.md"}}
    end

    test "also matches a single-segment value" do
      t = URITemplate.compile!("app://files/{+path}")

      assert URITemplate.match(t, "app://files/report.md") == {:ok, %{"path" => "report.md"}}
    end

    test "still never matches an empty value" do
      t = URITemplate.compile!("app://files/{+path}")

      assert URITemplate.match(t, "app://files/") == :nomatch
    end

    test "%2F decodes to a literal slash, same as writing it unescaped" do
      t = URITemplate.compile!("app://files/{+path}")

      assert URITemplate.match(t, "app://files/a%2Fb") == {:ok, %{"path" => "a/b"}}
      assert URITemplate.match(t, "app://files/a/b") == {:ok, %{"path" => "a/b"}}
    end

    test "invalid UTF-8 is still refused" do
      t = URITemplate.compile!("app://files/{+path}")

      assert URITemplate.match(t, "app://files/%FF") == :nomatch
    end

    test "the variable name excludes the leading +" do
      t = URITemplate.compile!("app://files/{+path}")

      assert t.vars == ["path"]
    end

    test "compile! rejects a {+var} that is not the template's final expression" do
      for bad <- [
            "app://{+path}/end",
            "app://{+a}/{+b}",
            "app://{+path}{other}"
          ] do
        assert_raise ArgumentError, fn -> URITemplate.compile!(bad) end
      end
    end

    test "compile! rejects {+} and {++x}" do
      assert_raise ArgumentError, fn -> URITemplate.compile!("app://files/{+}") end
      assert_raise ArgumentError, fn -> URITemplate.compile!("app://files/{++x}") end
    end

    test "a template that is only {+var} is legal and claims the whole URI" do
      t = URITemplate.compile!("{+everything}")

      assert URITemplate.match(t, "app://files/reports/2026-08-25.md") ==
               {:ok, %{"everything" => "app://files/reports/2026-08-25.md"}}

      assert URITemplate.match(t, "") == :nomatch
    end
  end

  test "a plain {var} still refuses a value containing or decoding to a slash" do
    t = URITemplate.compile!("app://items/{id}")

    assert URITemplate.match(t, "app://items/a/b") == :nomatch
    assert URITemplate.match(t, "app://items/a%2Fb") == :nomatch
  end
end
