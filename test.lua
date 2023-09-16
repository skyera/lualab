describe("a test", function()
    it("true", function()
        assert.True(1==1)
    end)

    it("yeah", function()
        assert.truthy("Yup")
    end)

    it("lots", function()
        assert.are.same({table="great"}, {table="great"})
        assert.True(1==2)
    end)
end)
