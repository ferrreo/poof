using System;

[assembly: Demo]
[Serializable, Route("box")]
public class Box {
    public int Value { get; set; }

    public string Format() {
        return $"value={Value}";
    }
}
