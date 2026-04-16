using UnityEngine;
using UnityEditor;
using UnityEditor.Rendering;

[CustomEditor(typeof(LookAtObject))]
class LookAtObjectEditor : Editor
{
    public override void OnInspectorGUI()
    {
        DrawDefaultInspector();

        LookAtObject lookAtObject = (LookAtObject)target;

        if(GUILayout.Button("Look At Target") && lookAtObject.target != null)
        {
            lookAtObject.source.LookAt(lookAtObject.target);
        }
    }
}


[ExecuteInEditMode]
public class LookAtObject : MonoBehaviour
{
    public Camera source;
    public Transform target; // The object to look at

    void OnValidate()
    {
        if(source != null && target != null)
        {
            source.transform.LookAt(target);
        }
    }

    void Awake()
    {
        source.depthTextureMode = DepthTextureMode.Depth;
        Shader.SetGlobalMatrix("_WorldToLight", source.worldToCameraMatrix);
        Shader.SetGlobalMatrix("_LightProjection", source.projectionMatrix);
    }

    void Update()
    {
        if(source != null && target != null)
        {
            source.transform.LookAt(target);
        }
    }

    void OnDrawGizmos()
    {
        Gizmos.color = Color.red;
        if(source != null)
        {
            Gizmos.DrawRay(source.transform.position, source.transform.forward * 2);
        }
    }
}
