package demo;

@java.lang.Deprecated(since="1.0")
public class Box {
    private final int value = 42;

    public String format() {
        return "value=" + value;
    }
}
