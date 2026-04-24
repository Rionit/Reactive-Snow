using UnityEngine;
using UnityEngine.Rendering;

[ExecuteInEditMode]
public class LightZBuffer : MonoBehaviour
{
    [SerializeField]
    Light targetLight;

    CommandBuffer commandBuffer;
    RenderTexture renderTexture;


    void OnEnable()
    {
        commandBuffer = new CommandBuffer { name = "LightZBufferCapture" };

        RenderTargetIdentifier shadowmap = new RenderTargetIdentifier(BuiltinRenderTextureType.CurrentActive);
        renderTexture = new RenderTexture(1920, 1080, 16, RenderTextureFormat.ARGB32);
        renderTexture.filterMode = FilterMode.Point;

        commandBuffer.SetShadowSamplingMode(shadowmap, ShadowSamplingMode.RawDepth);
        var id = new RenderTargetIdentifier(renderTexture);
        commandBuffer.Blit(shadowmap,id);



        commandBuffer.SetGlobalTexture("_LightZBuffer", id);
        targetLight.AddCommandBuffer(LightEvent.AfterShadowMap, commandBuffer);
    }

    void OnDisable()
    {
        if (commandBuffer != null)
        {
            commandBuffer.Release();
            commandBuffer = null;
        }

        if (renderTexture != null)
        {
            renderTexture.Release();
            renderTexture = null;
        }
    }

}
