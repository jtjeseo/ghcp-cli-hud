if (-not ('CopilotHud.JsonValue' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;

namespace CopilotHud {
    public sealed class JsonProperty {
        public string Name;
        public JsonValue Value;
    }
    public sealed class JsonValue {
        // Unknown values stay as raw JSON: no numeric rounding or date coercion.
        public string Kind, Raw, Text;
        public List<JsonProperty> Properties = new List<JsonProperty>();
        public JsonValue Get(string name) {
            for (int i = Properties.Count - 1; i >= 0; i--) {
                if (Properties[i].Name == name) { return Properties[i].Value; }
            }
            return null;
        }
        public static JsonValue Parse(string text) { return new JsonReader(text).Read(); }
    }
    sealed class JsonReader {
        readonly string text;
        int position;
        public JsonReader(string text) { this.text = text; }
        FormatException Invalid() { return new FormatException("Invalid HUD settings JSON."); }
        void Space() {
            while (position < text.Length && (text[position] == ' ' || text[position] == '\t' ||
                text[position] == '\r' || text[position] == '\n')) { position++; }
        }
        bool Take(char value) {
            if (position < text.Length && text[position] == value) { position++; return true; }
            return false;
        }
        void Need(char value) { if (!Take(value)) { throw Invalid(); } }
        bool Digit() { return position < text.Length && text[position] >= '0' && text[position] <= '9'; }
        string String() {
            Need('"');
            var value = new StringBuilder();
            while (position < text.Length) {
                char next = text[position++];
                if (next == '"') { return value.ToString(); }
                if (next < 32) { throw Invalid(); }
                if (next != '\\') { value.Append(next); continue; }
                if (position >= text.Length) { throw Invalid(); }
                next = text[position++];
                switch (next) {
                    case '"': case '\\': case '/': value.Append(next); break;
                    case 'b': value.Append('\b'); break;
                    case 'f': value.Append('\f'); break;
                    case 'n': value.Append('\n'); break;
                    case 'r': value.Append('\r'); break;
                    case 't': value.Append('\t'); break;
                    case 'u':
                        int code = 0;
                        for (int i = 0; i < 4; i++) {
                            if (position >= text.Length) { throw Invalid(); }
                            char hex = text[position++];
                            int digit = hex >= '0' && hex <= '9' ? hex - '0' :
                                hex >= 'a' && hex <= 'f' ? hex - 'a' + 10 :
                                hex >= 'A' && hex <= 'F' ? hex - 'A' + 10 : -1;
                            if (digit < 0) { throw Invalid(); }
                            code = code * 16 + digit;
                        }
                        value.Append((char)code);
                        break;
                    default: throw Invalid();
                }
            }
            throw Invalid();
        }
        void Number() {
            Take('-');
            if (!Take('0')) {
                if (!Digit() || text[position] == '0') { throw Invalid(); }
                while (Digit()) { position++; }
            }
            if (Take('.')) {
                if (!Digit()) { throw Invalid(); }
                while (Digit()) { position++; }
            }
            if (Take('e') || Take('E')) {
                if (!Take('+')) { Take('-'); }
                if (!Digit()) { throw Invalid(); }
                while (Digit()) { position++; }
            }
        }
        void Literal(string value) {
            if (position + value.Length > text.Length ||
                System.String.CompareOrdinal(text, position, value, 0, value.Length) != 0) { throw Invalid(); }
            position += value.Length;
        }
        JsonValue Value(int depth) {
            Space();
            if (position >= text.Length) { throw Invalid(); }
            int start = position;
            var value = new JsonValue();
            char next = text[position];
            if ((next == '{' || next == '[') && depth >= 256) { throw Invalid(); }
            if (next == '{') {
                value.Kind = "object";
                position++;
                Space();
                if (!Take('}')) {
                    do {
                        Space();
                        string name = String();
                        Space();
                        Need(':');
                        value.Properties.Add(new JsonProperty { Name = name, Value = Value(depth + 1) });
                        Space();
                        if (Take('}')) { break; }
                        Need(',');
                    } while (true);
                }
            } else if (next == '[') {
                value.Kind = "array";
                position++;
                Space();
                if (!Take(']')) {
                    do {
                        Value(depth + 1);
                        Space();
                        if (Take(']')) { break; }
                        Need(',');
                    } while (true);
                }
            } else if (next == '"') {
                value.Kind = "string";
                value.Text = String();
            } else if (next == 't') { value.Kind = "true"; Literal("true"); }
            else if (next == 'f') { value.Kind = "false"; Literal("false"); }
            else if (next == 'n') { value.Kind = "null"; Literal("null"); }
            else { value.Kind = "number"; Number(); }
            value.Raw = text.Substring(start, position - start);
            return value;
        }
        public JsonValue Read() {
            JsonValue value = Value(0);
            Space();
            if (position != text.Length) { throw Invalid(); }
            return value;
        }
    }
}
'@ -ErrorAction Stop
}
