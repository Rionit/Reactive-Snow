using System;
using StarterAssets;
using UnityEngine;

public class FollowPosition : MonoBehaviour
{
    public GameObject target;
    public Vector3 offset;
    private ThirdPersonController tpc;

    private void Start()
    {
        tpc = target.GetComponent<ThirdPersonController>();
    }

    void LateUpdate()
    {
        //if(tpc.Grounded)
        if(false)
            transform.position = target.transform.position - offset;
        else
            transform.position = new Vector3(target.transform.position.x, transform.position.y, target.transform.position.z);
    }
}
