import { inject, Service } from '@angular/core';
import { HttpClient } from '@angular/common/http';

@Service()
export class HttpHelper {


    private myHttp = inject(HttpClient)


    private baseURL = "http://localhost:8001"



    postSendMessage(body: any) {
        return this.myHttp.post(this.baseURL + "/post", {
            question: body.question,
            role: body.role
        })
    }


    postSendMessageGeneral(body: any) {
        return this.myHttp.post(`${this.baseURL}/generalMessage`, body);
    }



}
