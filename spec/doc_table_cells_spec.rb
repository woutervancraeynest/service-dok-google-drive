require "spec_helper"

RSpec.describe DocTableCells do
  def cell(text, rich: 0, nested: false)
    { text: text, rich_elements: rich, nested_table: nested }
  end

  describe ".normalize" do
    it "ignores case, surrounding whitespace, non-breaking spaces and a trailing colon" do
      expect(described_class.normalize("  Opstart\u00A0 Gesprek :\n")).to eq("opstart gesprek")
    end

    it "normalises Unicode composition" do
      decomposed = "E\u0301valuatie"

      expect(described_class.normalize(decomposed)).to eq(described_class.normalize("Évaluatie"))
    end
  end

  describe ".clean_value" do
    it "keeps inner line breaks and case but drops the trailing paragraph newline" do
      expect(described_class.clean_value("Chantal\nSofie\n")).to eq("Chantal\nSofie")
    end

    it "treats soft line breaks as line breaks" do
      expect(described_class.clean_value("a\u000Bb\n")).to eq("a\nb")
    end
  end

  describe ".cell_state" do
    it "classifies empty and filler-only cells as empty" do
      expect(described_class.cell_state(cell("\n"))).to eq("empty")
      expect(described_class.cell_state(cell("  ____ \n"))).to eq("empty")
      expect(described_class.cell_state(cell("…\n"))).to eq("empty")
    end

    it "recognises built-in Word placeholders regardless of case and final dot" do
      expect(described_class.cell_state(cell("Klik of tik om een datum in te voeren.\n"))).to eq("placeholder")
      expect(described_class.cell_state(cell("klik of tik om tekst in te voeren\n"))).to eq("placeholder")
      expect(described_class.cell_state(cell("Click or tap here to enter text.\n"))).to eq("placeholder")
    end

    it "recognises <token> placeholders and extra placeholders" do
      expect(described_class.cell_state(cell("<datum>\n"))).to eq("placeholder")
      expect(described_class.cell_state(cell("(invullen)\n"), placeholders: ["(invullen)"])).to eq("placeholder")
    end

    it "treats text, dashes, chips and nested tables as meaningful content" do
      expect(described_class.cell_state(cell("01/10/2026\n"))).to eq("filled")
      expect(described_class.cell_state(cell("-\n"))).to eq("filled")
      expect(described_class.cell_state(cell("\n", rich: 1))).to eq("filled")
      expect(described_class.cell_state(cell("\n", nested: true))).to eq("filled")
    end
  end

  describe ".parse_cell_id" do
    it "parses stable cell ids" do
      expect(described_class.parse_cell_id("t.0/2/1/3")).to eq(table_id: "t.0/2", row_index: 1, column_index: 3)
      expect(described_class.parse_cell_id("body/0/0/0")).to eq(table_id: "body/0", row_index: 0, column_index: 0)
    end

    it "rejects malformed ids" do
      expect(described_class.parse_cell_id("t.0/2/1")).to be_nil
      expect(described_class.parse_cell_id("t.0/x/1/1")).to be_nil
      expect(described_class.parse_cell_id(nil)).to be_nil
    end

    it "round-trips with .cell_id" do
      id = described_class.cell_id("t.abc", 4, 2, 1)

      expect(described_class.parse_cell_id(id)).to eq(table_id: "t.abc/4", row_index: 2, column_index: 1)
    end
  end

  describe ".resolve selector validation" do
    let(:parsed) { [{ tab_id: "t.0", tables: [], outside_paragraphs: [] }] }

    it "requires a row and column selector in grid mode" do
      result = described_class.resolve(parsed, row_selector: { "cell_text" => "A" })

      expect(result[:status]).to eq("invalid_selector")
    end

    it "rejects unknown anchor relations" do
      result = described_class.resolve(parsed, cell_selector: { "anchor_text" => "A", "relation" => "above" })

      expect(result[:status]).to eq("invalid_selector")
    end

    it "reports table_not_found when the document has no tables" do
      result = described_class.resolve(parsed, row_selector: { "cell_text" => "A" },
                                               column_selector: { "index" => 1 })

      expect(result[:status]).to eq("table_not_found")
    end
  end
end
