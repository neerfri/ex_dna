defmodule ExDNA.ReportTest do
  use ExUnit.Case, async: true

  alias ExDNA.Config
  alias ExDNA.Report

  setup do
    dir =
      Path.join(System.tmp_dir!(), "ex_dna_report_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.ex"), "defmodule A, do: nil")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "detection_time_ms is populated when provided", %{dir: dir} do
    config = Config.new(paths: [dir], reporters: [])
    report = Report.new([], config, 42)

    assert report.stats.detection_time_ms == 42
  end

  test "detection_time_ms defaults to 0", %{dir: dir} do
    config = Config.new(paths: [dir], reporters: [])
    report = Report.new([], config)

    assert report.stats.detection_time_ms == 0
  end

  test "ExDNA.analyze populates detection_time_ms", %{dir: dir} do
    report = ExDNA.analyze(paths: [dir], reporters: [])

    assert report.stats.detection_time_ms >= 0
  end
end
