using BankFas.Core.Lc;

namespace BankFas.Core.Tests.Text;

public sealed class FormFieldTransformTests
{
    [Fact]
    public void The_bank_form_transforms_are_pure_functions_of_the_value()   // FR-LCT-027, BR-LCT-020
    {
        Assert.Equal("15/03/2027", FormFieldTransform.Apply("DATE_DMY", new DateTime(2027, 3, 15), null));
        Assert.Equal("STEEL PIPES", FormFieldTransform.Apply("UPPER", "Steel pipes", null));
        Assert.Equal("X", FormFieldTransform.Apply("CHECKBOX_EQ", "SIGHT", "sight"));
        Assert.Equal("", FormFieldTransform.Apply("CHECKBOX_EQ", "ACCEPTANCE", "SIGHT"));
        Assert.Equal("", FormFieldTransform.Apply("NONE", null, null));
        Assert.Equal("3000000", FormFieldTransform.Apply("NONE", 3_000_000m, null));
        Assert.NotEqual("2027-03-15", FormFieldTransform.Apply("DATE_HIJRI", "2027-03-15", null));
    }
}
