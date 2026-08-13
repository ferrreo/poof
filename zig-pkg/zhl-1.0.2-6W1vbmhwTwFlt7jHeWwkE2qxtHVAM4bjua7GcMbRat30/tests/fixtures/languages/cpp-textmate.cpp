#include <vector>
template <typename T>
class Box {
public:
    T value;
};

int main() {
    // comment
    Box<int> box{42};
    return box.value;
}
